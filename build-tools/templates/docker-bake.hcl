variable "RUNTIME_IMAGE" {
  default = ""
}

group "default" {
  targets = ["release"]
}

target "test" {
  context    = "."
  dockerfile = "Dockerfile"
  target     = "test"
  args = {
    RUNTIME_IMAGE = RUNTIME_IMAGE
  }
}

target "release" {
  context    = "."
  dockerfile = "Dockerfile"
  target     = "release"
  args = {
    RUNTIME_IMAGE = RUNTIME_IMAGE
  }
}
