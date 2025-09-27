terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
    }
    null = {
      source = "hashicorp/null"
    }
    local = {
      source  = "hashicorp/local"
    }
  }
}

variable "trigger_dr_restore" {
  type        = bool
  description = "Set to true to trigger the DR restore API call."
  default     = false
}

variable "gcp_access_token" {
  type        = string
  description = "A valid GCP access token. (No longer strictly needed if using google_client_config)"
  default     = ""
  sensitive   = true
}

variable "consumer_project_id" {
  type        = string
  description = "Consumer project ID"
  default     = "kavishgupta-consumer-18"
}

variable "location" {
  type        = string
  description = "GCP region for the BackupDR service"
  default     = "asia-northeast1"
}

variable "target_zone" {
  type        = string
  description = "Target zone for the restored instance"
  default     = "asia-northeast1-c"
}

variable "restored_vm_name" {
  type        = string
  description = "Name for the restored VM"
  default     = "instance-11-restrd"
}

variable "backup_vault" {
  type        = string
  default     = "bv1"
}

variable "data_source" {
  type        = string
  default     = "ds1"
}

variable "backup_id" {
  type        = string
  default     = "b1"
}

variable "restore_network" {
  type        = string
  default     = "projects/kavishgupta-consumer-18/global/networks/test-restore"
}

variable "restore_subnetwork" {
  type        = string
  default     = "projects/kavishgupta-consumer-18/regions/asia-northeast1/subnetworks/test-subnet"
}

variable "service_account_email" {
  type        = string
  default     = "<REDACTED_EMAIL>"
}

locals {
  api_endpoint = "https://backupdr.googleapis.com"
  restore_path = "v1/projects/${var.consumer_project_id}/locations/${var.location}/backupVaults/${var.backup_vault}/dataSources/${var.data_source}/backups/${var.backup_id}:restore"
  restore_url  = "${local.api_endpoint}/${local.restore_path}"

  request_body = jsonencode({
    compute_instance_target_environment = {
      project = "nkuravi-cons-1"
      zone    = var.target_zone
    }
    compute_instance_restore_properties = {
      name               = var.restored_vm_name
      network_interfaces = [
        {
          network    = var.restore_network
          subnetwork = var.restore_subnetwork
        }
      ]
      service_accounts = [
        {
          email = var.service_account_email
        }
      ]
    }
  })
}

# Use google_client_config to get the access token at apply time
data "google_client_config" "default" {}

# Step 1: Trigger the initial restore operation (with pre-flight check)
resource "null_resource" "trigger_gcbdr_restore" {
  count = var.trigger_dr_restore ? 1 : 0

  triggers = {
    restore_url       = local.restore_url
    request_body      = local.request_body
    consumer_project  = var.consumer_project_id
    # IMPORTANT: Added restored_vm_name to triggers.
    # This ensures the check runs if the name changes.
    restored_vm_name  = var.restored_vm_name
  }

  provisioner "local-exec" {
    interpreter = ["/bin/sh", "-c"]
    command = <<-EOT
      set -e
      # Define variables from Terraform
      RESTORE_URL="${local.restore_url}"
      REQUEST_BODY='${local.request_body}'
      AUTH_TOKEN='${data.google_client_config.default.access_token}'
      CONSUMER_PROJECT_ID='${var.consumer_project_id}'
      TARGET_VM_NAME='${var.restored_vm_name}'
      TARGET_PROJECT='nkuravi-cons-1' # Hardcoded from your locals block
      TARGET_ZONE='${var.target_zone}'

      # --- PRE-FLIGHT CHECK ---
      # Check if the VM already exists in the target project/zone.
      echo "Checking if VM '$TARGET_VM_NAME' already exists in project '$TARGET_PROJECT'..."
      if gcloud compute instances describe "$TARGET_VM_NAME" --project="$TARGET_PROJECT" --zone="$TARGET_ZONE" >/dev/null 2>&1; then
        echo "VM '$TARGET_VM_NAME' already exists. Skipping restore API call."
        # Exit with 0 to indicate success, as no action is needed.
        exit 0
      else
        echo "VM does not exist. Proceeding with restore."
      fi
      # --- END PRE-FLIGHT CHECK ---

      echo "Triggering restore operation at: $RESTORE_URL"

      # Execute curl and capture the response
      RESPONSE=$(curl -s -X POST \
        -H "Authorization: Bearer $AUTH_TOKEN" \
        -H "Content-Type: application/json" \
        -H "X-Goog-User-Project: $CONSUMER_PROJECT_ID" \
        -d "$REQUEST_BODY" \
        "$RESTORE_URL")

      # Check if the JSON response contains an 'error' field.
      if echo "$RESPONSE" | jq -e '.error' > /dev/null; then
        echo "Error: Restore API call failed. API Response:"
        echo "$RESPONSE" | jq '.'
        exit 1
      fi

      echo "$RESPONSE" > "${path.module}/gcbdr_restore_operation_response.json"
      echo "Restore operation triggered successfully. Response saved to gcbdr_restore_operation_response.json"
    EOT
  }
}
# Read the operation response from the file
data "local_file" "gcbdr_restore_operation_response" {
  count = var.trigger_dr_restore ? 1 : 0
  filename = "${path.module}/gcbdr_restore_operation_response.json"
  depends_on = [null_resource.trigger_gcbdr_restore]
}

# Step 2: Poll the operation
resource "null_resource" "poll_restore_operation" {
  count = var.trigger_dr_restore ? 1 : 0

  triggers = {
    operation_body_hash = var.trigger_dr_restore ? sha256(data.local_file.gcbdr_restore_operation_response[0].content) : ""
  }

  depends_on = [data.local_file.gcbdr_restore_operation_response]

  provisioner "local-exec" {
    # CHANGED interpreter to /bin/sh
    interpreter = ["/bin/sh", "-c"]
    command = <<-EOT
      set -e
      sleep 2 # Give time for the file to be written

      OPERATION_INITIAL_RESPONSE_FILE="${path.module}/gcbdr_restore_operation_response.json"

      if [ ! -f "$OPERATION_INITIAL_RESPONSE_FILE" ]; then
        echo "Error: Operation response file not found!"
        exit 1
      fi

      OPERATION_NAME=$(jq -r '.name' "$OPERATION_INITIAL_RESPONSE_FILE")
      if [ -z "$OPERATION_NAME" ] || [ "$OPERATION_NAME" == "null" ]; then
        echo "Error: Could not parse operation name from response file."
        cat "$OPERATION_INITIAL_RESPONSE_FILE"
        exit 1
      fi

      OPERATION_URL="https://backupdr.googleapis.com/v1/$OPERATION_NAME"
      AUTH_TOKEN='${data.google_client_config.default.access_token}'
      CONSUMER_PROJECT_ID='${var.consumer_project_id}'

      echo "Polling operation at: $OPERATION_URL"

      i=1
      while [ $i -le 40 ]; do
        RESPONSE=$(curl --fail -s -H "Authorization: Bearer $AUTH_TOKEN" -H "Content-Type: application/json" -H "X-Goog-User-Project: $CONSUMER_PROJECT_ID" "$OPERATION_URL")

        if [ $? -ne 0 ]; then
          echo "Attempt $i: curl command failed to poll operation. Retrying..."
          sleep 15
          i=$((i + 1))
          continue
        fi

        DONE_STATUS=$(echo "$RESPONSE" | jq -r '.done')
        echo "Attempt $i: Polling... Operation done status is '$DONE_STATUS'."

        if [ "$DONE_STATUS" = "true" ]; then
          echo "Operation has completed."
          if echo "$RESPONSE" | jq -e '.error' > /dev/null; then
            echo "Final Status: FAILED"
            echo "$RESPONSE" | jq '.'
            echo "$RESPONSE" > "${path.module}/operation_result.json"
            exit 1
          else
            echo "Final Status: SUCCESS"
            echo "$RESPONSE" > "${path.module}/operation_result.json"
            exit 0
          fi
        fi
        sleep 15
        i=$((i + 1))
      done

      echo "Error: Operation polling timed out after 10 minutes."
      exit 1
    EOT
  }
}

# Step 3: Read the result
data "local_file" "operation_result" {
  count = var.trigger_dr_restore ? 1 : 0
  filename = "${path.module}/operation_result.json"
  depends_on = [null_resource.poll_restore_operation]
}

# --- Outputs ---
output "restore_trigger_status" {
  description = "Status of the initial restore API call trigger."
  value       = var.trigger_dr_restore ? "Restore attempt initiated." : "Restore not triggered."
}

output "initial_operation_name" {
  description = "The name of the long-running operation from the initial API call."
  value       = var.trigger_dr_restore ? try(jsondecode(data.local_file.gcbdr_restore_operation_response[0].content).name, "Error reading name") : "N/A"
}

# --- Outputs ---

# (Keep your other outputs as they are)

output "final_operation_details" {
  description = "The full JSON body of the completed operation after polling."
  # The 'type' argument is removed as it's not supported in output blocks.
  # Terraform will correctly infer the type as 'string' from the value below.
  value       = var.trigger_dr_restore ? try(data.local_file.operation_result[0].content, "{}") : "{}"
}