## Terraform HTTP backend
Zero dependency Zig implementation of a server for [terraform http backend client](https://github.com/hashicorp/terraform/blob/main/internal/backend/remote-state/http/client.go)

__WARNING__: Zig is still not stable, as well as the provided software.
It is highly advised to host it behind a proper reverse proxy (e.g. nginx) capable of encryption/auth/timeouts/ratelimits/etc

### Build
See [CI](.github/workflows/ci.yml)

### Usage
Server `PORT` (`3030`), `HOST` (`0.0.0.0`), and thread `POOL_SIZE` (CPU count) can be changed using env variables

Terraform example config:
```tf
terraform {
  backend "http" {
    address        = "http://localhost:3030/uniq_project_name"
    lock_address   = "http://localhost:3030/uniq_project_name"
    unlock_address = "http://localhost:3030/uniq_project_name"
  }
}
```

### Notes
All saved states are immutable (unless purged) and saved on file system under `./state/uniq_project_name` where:
- `./<number>.terraform.tfstate` where number starts from 1 and is incremented on each state save
- `./counter` stores the current number
- `./lockinfo.json` stores current lock info

