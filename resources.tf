
## Main

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 6.0"
    }
  }
}

locals {
  apis = distinct(concat([
    "eventarc.googleapis.com",
    "eventarcpublishing.googleapis.com",
    "iam.googleapis.com",
    "cloudresourcemanager.googleapis.com",
  ], var.extra_apis))

  # Advanced pipelines support only:
  # - http_endpoint (Cloud Run / Cloud Functions HTTP / generic HTTP)
  # - message_bus (fan-out / chaining)
  advanced_pipeline_destinations = {
    for k, v in var.advanced_pipelines : k => v
    if contains(["http_endpoint", "message_bus"], v.destination.type)
  }

  standard_triggers = var.enable_standard_triggers ? var.standard_triggers : {}
}

resource "google_project_service" "apis" {
  for_each           = toset(local.apis)
  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}

data "google_project" "this" {
  project_id  = var.project_id
  depends_on  = [google_project_service.apis]
}

# -----------------------------
# Eventarc Advanced: Message Bus
# -----------------------------
resource "google_eventarc_message_bus" "bus" {
  project        = var.project_id
  location       = var.region
  message_bus_id = var.bus_id

  # Optional fields (safe defaults if unset)
  dynamic "crypto_key_name" {
    for_each = var.bus_kms_key == null ? [] : [1]
    content  = var.bus_kms_key
  }

  depends_on = [google_project_service.apis]
}

# Google sources -> bus (enables direct Google events to bus)
resource "google_eventarc_google_api_source" "google_sources" {
  count               = var.enable_google_sources ? 1 : 0
  project             = var.project_id
  location            = var.region
  google_api_source_id = var.google_api_source_id
  destination         = google_eventarc_message_bus.bus.id

  depends_on = [google_eventarc_message_bus.bus]
}

# --------------------------------
# Eventarc Advanced: Pipelines
# (1 pipeline -> 1 destination)
# --------------------------------
resource "google_eventarc_pipeline" "pipeline" {
  for_each    = local.advanced_pipeline_destinations

  project     = var.project_id
  location    = var.region
  pipeline_id = each.value.pipeline_id

  destinations {
    # Destination: HTTP endpoint (Cloud Run / Functions HTTP / Internal HTTP)
    dynamic "http_endpoint" {
      for_each = each.value.destination.type == "http_endpoint" ? [1] : []
      content {
        uri = each.value.destination.uri
      }
    }

    # Destination: Another Eventarc Advanced bus (fan-out / chaining)
    dynamic "message_bus" {
      for_each = each.value.destination.type == "message_bus" ? [1] : []
      content {
        message_bus = each.value.destination.message_bus_id
      }
    }

    # Optional auth for HTTP endpoints (OIDC)
    dynamic "authentication_config" {
      for_each = each.value.destination.type == "http_endpoint" && each.value.destination.oidc_service_account != null ? [1] : []
      content {
        google_oidc {
          service_account = each.value.destination.oidc_service_account
          audience        = each.value.destination.oidc_audience
        }
      }
    }
  }

  depends_on = [google_eventarc_message_bus.bus]
}

# --------------------------------
# Eventarc Advanced: Enrollments
# (subscription + CEL match)
# --------------------------------
resource "google_eventarc_enrollment" "enrollment" {
  for_each       = local.advanced_pipeline_destinations

  project        = var.project_id
  location       = var.region
  enrollment_id  = each.value.enrollment_id

  message_bus    = google_eventarc_message_bus.bus.id
  destination    = google_eventarc_pipeline.pipeline[each.key].id
  cel_match      = each.value.cel_match

  depends_on = [google_eventarc_pipeline.pipeline]
}

# -------------------------------------------------------------------
# OPTIONAL: Eventarc Standard triggers for targets not in Advanced pipeline
# - Workflows, Cloud Run functions interface, Internal HTTP endpoints, etc.
# -------------------------------------------------------------------
resource "google_eventarc_trigger" "standard" {
  for_each = local.standard_triggers

  project  = var.project_id
  location = each.value.location

  name = each.value.name

  dynamic "matching_criteria" {
    for_each = each.value.matching_criteria
    content {
      attribute = matching_criteria.value.attribute
      value     = matching_criteria.value.value
    }
  }

  destination {
    dynamic "cloud_run_service" {
      for_each = each.value.destination.type == "cloud_run" ? [1] : []
      content {
        service = each.value.destination.cloud_run_service
        region  = each.value.destination.cloud_run_region
        path    = each.value.destination.path
      }
    }

    dynamic "workflow" {
      for_each = each.value.destination.type == "workflows" ? [1] : []
      content {
        workflow = each.value.destination.workflow_id
      }
    }

    # For Cloud Run functions / Cloud Functions (2nd gen), the destination can still be Cloud Run interface.
    # Many teams just target the function's HTTPS URL using an internal HTTP endpoint option or use the function interface.
    dynamic "http_endpoint" {
      for_each = each.value.destination.type == "http" ? [1] : []
      content {
        uri = each.value.destination.uri
      }
    }
  }

  # Optional transport topic (Pub/Sub as provider/transport)
  dynamic "transport" {
    for_each = each.value.transport_pubsub_topic != null ? [1] : []
    content {
      pubsub {
        topic = each.value.transport_pubsub_topic
      }
    }
  }

  service_account = each.value.service_account

  depends_on = [google_project_service.apis]
}
######################################################
Variables 
variable "project_id" { type = string }
variable "region"     { type = string }

# APIs
variable "extra_apis" {
  description = "Extra APIs to enable (e.g., run.googleapis.com, workflows.googleapis.com, pubsub.googleapis.com)"
  type        = list(string)
  default     = []
}

# -------------------------
# Eventarc Advanced: Bus
# -------------------------
variable "bus_id" {
  description = "Eventarc Advanced message bus ID"
  type        = string
}

variable "bus_kms_key" {
  description = "Optional CMEK CryptoKey full resource name for the bus"
  type        = string
  default     = null
}

variable "enable_google_sources" {
  description = "Enable Google sources publishing directly into the Advanced bus"
  type        = bool
  default     = true
}

variable "google_api_source_id" {
  description = "ID for google_eventarc_google_api_source"
  type        = string
  default     = "google-api-source"
}

# --------------------------------------
# Eventarc Advanced: Pipelines/Enrollments
# --------------------------------------
variable "advanced_pipelines" {
  description = <<EOT
Map of pipeline+enrollment definitions.
Each entry creates:
- google_eventarc_pipeline
- google_eventarc_enrollment (CEL match -> pipeline)

destination.type:
- "http_endpoint"  (Cloud Run / Functions HTTP / any HTTP)
- "message_bus"    (fan-out to another Advanced bus)
EOT

  type = map(object({
    pipeline_id    = string
    enrollment_id  = string
    cel_match      = string

    destination = object({
      type = string

      # http_endpoint
      uri                 = optional(string)
      oidc_service_account = optional(string)
      oidc_audience        = optional(string)

      # message_bus
      message_bus_id = optional(string)
    })
  }))
}

# -------------------------
# Optional: Eventarc Standard triggers
# -------------------------
variable "enable_standard_triggers" {
  description = "Create Eventarc Standard triggers for targets not supported directly by Advanced pipelines (e.g., Workflows)"
  type        = bool
  default     = false
}

variable "standard_triggers" {
  description = <<EOT
Map of Eventarc Standard triggers.
Use for Workflows, Cloud Run functions interface, internal HTTP endpoints, etc.
EOT

  type = map(object({
    name     = string
    location = string

    matching_criteria = list(object({
      attribute = string
      value     = string
    }))

    destination = object({
      type = string # cloud_run | workflows | http

      # cloud_run
      cloud_run_service = optional(string)
      cloud_run_region  = optional(string)
      path              = optional(string)

      # workflows
      workflow_id = optional(string)

      # http
      uri = optional(string)
    })

    # Optional: if using Pub/Sub as provider/transport
    transport_pubsub_topic = optional(string)

    # Service account used by the trigger to invoke destination
    service_account = string
  }))
  default = {}
}
################################################################################

### outpus

output "advanced_bus_id" {
  value = google_eventarc_message_bus.bus.id
}

output "advanced_pipeline_ids" {
  value = { for k, v in google_eventarc_pipeline.pipeline : k => v.id }
}

output "advanced_enrollment_ids" {
  value = { for k, v in google_eventarc_enrollment.enrollment : k => v.id }
}

output "google_api_source_id" {
  value       = try(google_eventarc_google_api_source.google_sources[0].id, null)
  description = "Null if enable_google_sources=false"
}

#######################################################################################

module "eventarc_arch" {
  source     = "./modules/eventarc_advanced_arch"
  project_id = var.project_id
  region     = "us-central1"

  # Enable target APIs you actually use
  extra_apis = [
    "run.googleapis.com",
    "workflows.googleapis.com",
    "pubsub.googleapis.com",
  ]

  bus_id = "central-bus"

  enable_google_sources  = true
  google_api_source_id   = "google-api-source"

  # Advanced pipelines (diagram: Cloud Run / Cloud Run functions / HTTP / message bus)
  advanced_pipelines = {
    to_cloud_run = {
      pipeline_id   = "pl-cloudrun"
      enrollment_id = "en-cloudrun"
      cel_match     = "message.type.startsWith('google.cloud')"

      destination = {
        type                 = "http_endpoint"
        uri                  = "https://YOUR-CLOUDRUN-URL.a.run.app"
        oidc_service_account = "eventarc-delivery@${var.project_id}.iam.gserviceaccount.com"
        oidc_audience        = null
      }
    }

    to_cloud_function_http = {
      pipeline_id   = "pl-function"
      enrollment_id = "en-function"
      cel_match     = "message.type == 'com.yourco.custom.v1.created'"

      destination = {
        type                 = "http_endpoint"
        uri                  = "https://REGION-PROJECT.cloudfunctions.net/YOUR_HTTP_FUNCTION"
        oidc_service_account = "eventarc-delivery@${var.project_id}.iam.gserviceaccount.com"
        oidc_audience        = null
      }
    }

    fanout_to_another_bus = {
      pipeline_id   = "pl-fanout"
      enrollment_id = "en-fanout"
      cel_match     = "message.type.contains('audit')"

      destination = {
        type          = "message_bus"
        message_bus_id = "projects/${var.project_id}/locations/us-central1/messageBuses/downstream-bus"
      }
    }
  }

  # Optional Standard triggers (diagram: Workflows)
  enable_standard_triggers = true
  standard_triggers = {
    pubsub_to_workflows = {
      name     = "trg-pubsub-to-wf"
      location = "us-central1"

      matching_criteria = [
        { attribute = "type", value = "google.cloud.pubsub.topic.v1.messagePublished" }
      ]

      destination = {
        type        = "workflows"
        workflow_id = "projects/${var.project_id}/locations/us-central1/workflows/my-workflow"
      }

      transport_pubsub_topic = "projects/${var.project_id}/topics/my-topic"
      service_account        = "eventarc-trigger@${var.project_id}.iam.gserviceaccount.com"
    }
  }
}
####################################################################################

