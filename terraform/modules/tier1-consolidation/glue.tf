# Glue Data Catalog database and the normalised network-events table.
# The table is used both by Athena (query) and by the Firehose data-format
# conversion (JSON -> Parquet on write).
resource "aws_glue_catalog_database" "netobs" {
  name = local.glue_database_name
}

resource "aws_glue_catalog_table" "network_events" {
  name          = local.glue_table_name
  database_name = aws_glue_catalog_database.netobs.name
  table_type    = "EXTERNAL_TABLE"

  parameters = {
    classification       = "parquet"
    "projection.enabled" = "true"
    # Partition projection avoids a crawler: dt is projected as a date range.
    "projection.dt.type"          = "date"
    "projection.dt.format"        = "yyyy-MM-dd"
    "projection.dt.range"         = "2024-01-01,NOW"
    "projection.dt.interval"      = "1"
    "projection.dt.interval.unit" = "DAYS"
    "storage.location.template"   = "s3://${local.analysis_bucket_name}/${local.consolidated_prefix}dt=$${dt}/"
  }

  partition_keys {
    name = "dt"
    type = "string"
  }

  storage_descriptor {
    location      = "s3://${local.analysis_bucket_name}/${local.consolidated_prefix}"
    input_format  = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetOutputFormat"

    ser_de_info {
      serialization_library = "org.apache.hadoop.hive.ql.io.parquet.serde.ParquetHiveSerDe"
    }

    # The common 5-tuple + context schema every source is normalised into.
    columns {
      name = "event_time"
      type = "string"
    }
    columns {
      name    = "source_type"
      type    = "string"
      comment = "nfw_alert | dns_firewall | tgw_flow | vpc_flow | cloudtrail (NFW flow logs are in the separate nfw_flow_s3 table)"
    }
    columns {
      name    = "action"
      type    = "string"
      comment = "allow | deny | alert | pass | block"
    }
    columns {
      name = "src_ip"
      type = "string"
    }
    columns {
      name = "dst_ip"
      type = "string"
    }
    columns {
      name = "src_port"
      type = "int"
    }
    columns {
      name = "dst_port"
      type = "int"
    }
    columns {
      name    = "protocol"
      type    = "string"
      comment = "normalised: tcp | udp | icmp"
    }
    columns {
      name    = "rule_sid"
      type    = "string"
      comment = "Suricata SID -> log-to-rule deep link"
    }
    columns {
      name    = "domain"
      type    = "string"
      comment = "DNS query name / TLS SNI / HTTP host"
    }
    columns {
      name = "tls_sni"
      type = "string"
    }
    columns {
      name = "geo_country"
      type = "string"
    }
    columns {
      name = "account_id"
      type = "string"
    }
    columns {
      name = "region"
      type = "string"
    }
    columns {
      name = "vpc_id"
      type = "string"
    }
    columns {
      name = "bytes"
      type = "bigint"
    }
    columns {
      name = "packets"
      type = "bigint"
    }
    columns {
      name    = "raw"
      type    = "string"
      comment = "original record, preserved verbatim"
    }
  }
}
