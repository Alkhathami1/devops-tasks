# NOTE: no output here includes the account id. The repository is public, and
# an ARN embeds the account. scripts/redact.sh strips anything that slips into
# an evidence log.

output "archive_bucket" {
  description = "S3 bucket receiving the .ts archive segments."
  value       = aws_s3_bucket.archive.bucket
}

output "channel_id" {
  description = "MediaLive channel id, used by scripts/channel.sh to start and stop it."
  value       = aws_medialive_channel.this.id
}

output "channel_name" {
  value = aws_medialive_channel.this.name
}

output "input_id" {
  value = aws_medialive_input.this.id
}

output "input_destinations" {
  description = "The RTP endpoints to push the contribution feed to."
  value       = aws_medialive_input.this.destinations
}

output "archive_prefix" {
  value = var.archive_prefix
}

output "region" {
  value = var.region
}
