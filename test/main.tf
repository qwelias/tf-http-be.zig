terraform {
  required_version = ">= 1"

  backend "http" {
    address = "http://0.0.0.0:3030/NAME"
    lock_address = "http://0.0.0.0:3030/NAME"
    unlock_address = "http://0.0.0.0:3030/NAME"
  }
}
