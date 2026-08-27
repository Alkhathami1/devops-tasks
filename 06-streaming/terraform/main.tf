terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
  # Local state, same reasoning as Task 05: single operator, one session, and
  # the estate is destroyed at the end. State holds the input endpoints and is
  # gitignored. A shared setup would use an S3 backend with DynamoDB locking.
}

provider "aws" {
  region = var.region
  # Credentials come from the standard chain (~/.aws/credentials via
  # `aws configure`). Nothing credential-shaped appears in this repository:
  # the repo is public and scripts/audit.sh fails the build on anything that
  # looks like a key.
  default_tags {
    tags = var.tags
  }
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# A suffix so the bucket name is globally unique without embedding the account
# id, which must not appear in a public repository.
resource "random_id" "suffix" {
  byte_length = 4
}

locals {
  bucket_name = "${var.name_prefix}-archive-${random_id.suffix.hex}"
}

# ---------------------------------------------------------------------------
# S3 — the archive destination
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "archive" {
  bucket = local.bucket_name

  # The exercise destroys everything at the end, and MediaLive will have
  # written objects that Terraform does not track. Without this, destroy fails
  # on a non-empty bucket and leaves it behind - billing storage, and exactly
  # the orphan class the teardown check hunts for.
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "archive" {
  bucket                  = aws_s3_bucket.archive.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "archive" {
  bucket = aws_s3_bucket.archive.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# A short expiry so a forgotten object cannot accumulate cost indefinitely.
resource "aws_s3_bucket_lifecycle_configuration" "archive" {
  bucket = aws_s3_bucket.archive.id
  rule {
    id     = "expire-archive-segments"
    status = "Enabled"
    filter {}
    expiration {
      days = 1
    }
  }
}

# ---------------------------------------------------------------------------
# IAM — the role MediaLive assumes to write to S3
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "medialive_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["medialive.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "medialive" {
  name               = "${var.name_prefix}-medialive-role"
  assume_role_policy = data.aws_iam_policy_document.medialive_assume.json
}

data "aws_iam_policy_document" "medialive_s3" {
  # Scoped to this one bucket. The AWS-managed MediaLiveFullAccess policy grants
  # far more than an archive output needs.
  statement {
    effect = "Allow"
    actions = [
      "s3:PutObject",
      "s3:GetObject",
      "s3:DeleteObject",
      "s3:ListBucket",
      "s3:GetBucketLocation",
    ]
    resources = [
      aws_s3_bucket.archive.arn,
      "${aws_s3_bucket.archive.arn}/*",
    ]
  }

  # MediaLive writes its own logs.
  statement {
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogStreams",
      "logs:DescribeLogGroups",
    ]
    resources = ["arn:aws:logs:*:*:*"]
  }

  # Required for a push input: MediaLive creates ENIs to receive the feed.
  statement {
    effect = "Allow"
    actions = [
      "ec2:DescribeSubnets",
      "ec2:DescribeNetworkInterfaces",
      "ec2:DescribeSecurityGroups",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "medialive_s3" {
  name   = "${var.name_prefix}-medialive-s3"
  role   = aws_iam_role.medialive.id
  policy = data.aws_iam_policy_document.medialive_s3.json
}

# ---------------------------------------------------------------------------
# MediaLive input
#
# RTP_PUSH rather than RTMP_PUSH, and the reason is measured rather than
# assumed (see scripts/analysis.sh):
#
#   Classic RTMP/FLV has no CodecID for HEVC. Enhanced RTMP (2023) adds one and
#   modern ffmpeg implements it - the local test muxes HEVC into FLV without
#   complaint - but MediaLive's RTMP_PUSH input expects H.264 and will not
#   ingest it. The blocker is the receiver, not the container.
#
#   RTP_PUSH carries MPEG-TS, which has a native stream type for HEVC (0x24),
#   and ffmpeg pushes it with `-f rtp_mpegts`.
# ---------------------------------------------------------------------------

resource "aws_medialive_input_security_group" "this" {
  whitelist_rules {
    # The operator's public address. Defaults to 0.0.0.0/0 for a short-lived
    # exercise, which is called out in the report rather than hidden - a push
    # input open to the internet is a real weakening, mitigated here only by
    # the channel existing for minutes.
    cidr = var.ingest_source_cidr
  }
}

resource "aws_medialive_input" "this" {
  name                  = "${var.name_prefix}-input"
  type                  = "RTP_PUSH"
  input_security_groups = [aws_medialive_input_security_group.this.id]
}

# ---------------------------------------------------------------------------
# MediaLive channel
# ---------------------------------------------------------------------------

resource "aws_medialive_channel" "this" {
  name = "${var.name_prefix}-channel"

  # SINGLE_PIPELINE, not STANDARD. STANDARD runs two independent pipelines in
  # separate AZs for redundancy and bills for BOTH - it doubles the hourly
  # rate. Redundancy is not what this exercise is demonstrating.
  channel_class = "SINGLE_PIPELINE"
  role_arn      = aws_iam_role.medialive.arn

  input_specification {
    codec            = var.input_codec
    input_resolution = "HD"
    maximum_bitrate  = "MAX_20_MBPS"
  }

  input_attachments {
    input_attachment_name = "primary"
    input_id              = aws_medialive_input.this.id
  }

  destinations {
    id = "archive-destination"
    settings {
      url = "s3ssl://${aws_s3_bucket.archive.bucket}/${var.archive_prefix}"
    }
  }

  encoder_settings {
    timecode_config {
      source = "SYSTEMCLOCK"
    }

    # --- video: HEVC at the required bitrate ------------------------------
    video_descriptions {
      name   = "video-hevc-1080p"
      width  = 1920
      height = 1080

      # Deinterlace/scale behaviour. The source is progressive already.
      respond_to_afd   = "NONE"
      scaling_behavior = "DEFAULT"
      sharpness        = 50

      codec_settings {
        h265_settings {
          bitrate           = var.video_bitrate
          rate_control_mode = "CBR"

          # 2-second GOP. This sets the minimum granularity at which the
          # ARCHIVE output can cut a segment, because segments break on IDR.
          gop_size       = 2
          gop_size_units = "SECONDS"

          framerate_numerator   = 60
          framerate_denominator = 1

          # Main profile, 8-bit 4:2:0 - widest decoder support. MAIN_10BIT
          # would cost bitrate for no gain from an 8-bit source.
          profile = "MAIN"
          tier    = "MAIN"
          level   = "H265_LEVEL_AUTO"

          # 4:2:0 8-bit.
          color_metadata = "INSERT"

          # Adaptive quantisation, the MediaLive equivalent of x265 aq-mode.
          adaptive_quantization = "HIGH"

          # B-frames between reference frames. Compression gain; acceptable
          # because this is contribution, not interactive.
          gop_closed_cadence = 1

          scene_change_detect = "DISABLED"

          buf_size    = var.video_bitrate * 2
          max_bitrate = var.video_bitrate
        }
      }
    }

    # --- audio: AAC at the required bitrate --------------------------------
    audio_descriptions {
      name                  = "audio-aac"
      audio_selector_name   = "default"
      audio_type_control    = "FOLLOW_INPUT"
      language_code_control = "FOLLOW_INPUT"

      codec_settings {
        aac_settings {
          bitrate           = var.audio_bitrate
          coding_mode       = "CODING_MODE_2_0"
          sample_rate       = 48000
          profile           = "LC"
          rate_control_mode = "CBR"
        }
      }
    }

    # --- ARCHIVE output group: .ts segments into S3 ------------------------
    output_groups {
      name = "archive"

      output_group_settings {
        archive_group_settings {
          destination {
            destination_ref_id = "archive-destination"
          }
          # Segment length. Each segment is a complete, independently playable
          # .ts file, cut on an IDR boundary.
          rollover_interval = var.segment_seconds
        }
      }

      outputs {
        output_name             = "archive-hevc"
        video_description_name  = "video-hevc-1080p"
        audio_description_names = ["audio-aac"]

        output_settings {
          archive_output_settings {
            name_modifier = "-hevc1080p60"
            extension     = "ts"
            container_settings {
              m2ts_settings {
                # MPEG-TS. Chosen over MXF for segmentability and error
                # resilience - see the container comparison in the report.
                audio_buffer_model   = "ATSC"
                audio_frames_per_pes = 4
                bitrate              = var.video_bitrate + var.audio_bitrate + 1000000
                buffer_model         = "MULTIPLEX"
                rate_mode            = "CBR"
                pcr_control          = "PCR_EVERY_PES_PACKET"
                segmentation_markers = "NONE"
              }
            }
          }
        }
      }
    }
  }

  # Two independent guards against an accidental long-running channel: the
  # start/stop is driven by scripts/channel.sh, and destroy tears it down.
  lifecycle {
    ignore_changes = [tags_all]
  }
}
