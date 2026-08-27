variable "region" {
  description = "AWS region. eu-central-1 per the operator's configured default."
  type        = string
  default     = "eu-central-1"
}

variable "name_prefix" {
  description = "Prefix for every named resource, so teardown can find them all."
  type        = string
  default     = "task06"
}

variable "video_bitrate" {
  description = "HEVC output bitrate in bps. 12 Mbps = 0.0965 bpp at 1080p60."
  type        = number
  default     = 12000000
}

variable "audio_bitrate" {
  description = "AAC output bitrate in bps. The requirement floor is 192 kbps."
  type        = number
  default     = 192000
}

variable "segment_seconds" {
  description = "ARCHIVE segment length. Must be a multiple of the 2s GOP so segments cut on IDR."
  type        = number
  default     = 10
}

variable "archive_prefix" {
  description = "Key prefix inside the bucket for the archive segments."
  type        = string
  default     = "live"
}

variable "input_codec" {
  description = <<-EOT
    Codec of the CONTRIBUTION feed, which is separate from the output encode.
    The channel always encodes HEVC for the archive; this is what MediaLive
    must decode on the way in.
  EOT
  type        = string
  default     = "HEVC"
}

variable "ingest_source_cidr" {
  description = <<-EOT
    Source permitted to push to the RTP input.

    0.0.0.0/0 by default because the operator address is dynamic and the
    channel lives for minutes. That is a real weakening and is stated in the
    report rather than hidden; a fixed address should be pinned here.
  EOT
  type        = string
  default     = "0.0.0.0/0"
}

variable "tags" {
  description = "Applied to everything, so an orphan can be found by tag."
  type        = map(string)
  default = {
    project = "devops-tasks"
    task    = "06-streaming"
    managed = "terraform"
  }
}
