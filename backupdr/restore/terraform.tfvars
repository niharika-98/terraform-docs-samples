# File: dr-orchestrator/terraform.tfvars
trigger_dr_restore    = true
consumer_project_id   = "proj1"
location              = "us-central1"
target_zone           = "us-central1-c"
restored_vm_name      = "instance-11-restrd-tf-triggered4000" # Maybe a new name to avoid conflicts
backup_vault          = "vault-rest"
data_source           = "7308242de1xxxxxxxxxxxxxxxxx"
backup_id             = "da676d02-xxxx-xxxx-xxxx-46182bc2ad77"
restore_network       = "projects/proj/global/networks/test-restore"
restore_subnetwork    = "projects/proj/regions/us-central1/subnetworks/test-rest"
service_account_email = "sample@proj.iam.gserviceaccount.com" # Make sure this is a valid SA email with permissions