# AWS Network Firewall flow logs are already delivered to an existing S3 bucket by
# the landing zone. Rather than mutate that bucket's event notifications, the module
# catalogs the flow logs in place as a dedicated Athena table so they can be queried
# alongside the normalised store and correlated at query time on the 5-tuple + time.
#
# The flow logs are gzipped Suricata EVE JSON. Refine `location` below to the exact
# prefix if the bucket also holds other content.

resource "aws_glue_catalog_table" "nfw_flow_s3" {
  count         = var.existing_nfw_flow_logs_bucket_name != "" ? 1 : 0
  name          = "nfw_flow_s3"
  database_name = aws_glue_catalog_database.netobs.name
  table_type    = "EXTERNAL_TABLE"

  parameters = {
    classification  = "json"
    compressionType = "gzip"
  }

  storage_descriptor {
    location      = "s3://${var.existing_nfw_flow_logs_bucket_name}/"
    input_format  = "org.apache.hadoop.mapred.TextInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.HiveIgnoreKeyTextOutputFormat"

    ser_de_info {
      serialization_library = "org.openx.data.jsonserde.JsonSerDe"
      parameters = {
        "ignore.malformed.json" = "true"
      }
    }

    columns {
      name = "timestamp"
      type = "string"
    }
    columns {
      name = "event_type"
      type = "string"
    }
    columns {
      name = "src_ip"
      type = "string"
    }
    columns {
      name = "src_port"
      type = "int"
    }
    columns {
      name = "dest_ip"
      type = "string"
    }
    columns {
      name = "dest_port"
      type = "int"
    }
    columns {
      name = "proto"
      type = "string"
    }
    columns {
      name = "netflow"
      type = "struct<pkts:bigint,bytes:bigint,start:string,end:string,age:int>"
    }
  }
}
