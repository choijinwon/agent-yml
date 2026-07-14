#!/usr/bin/env ruby
require "json"
require "yaml"

def assert(condition, message)
  raise message unless condition
end

yaml = YAML.safe_load(File.read("workflowtemplate.yaml"), aliases: true)
json = JSON.parse(File.read("workflowtemplate.json"))
assert(yaml == json, "workflowtemplate YAML and JSON differ")

if File.exist?("workflowtemplate.annotated.jsonc")
  jsonc_without_comments = File.readlines("workflowtemplate.annotated.jsonc")
    .reject { |line| line.lstrip.start_with?("//") }
    .join
  assert(JSON.parse(jsonc_without_comments) == json, "annotated JSONC and workflowtemplate JSON differ")
end

templates = yaml.fetch("spec").fetch("templates")
by_name = templates.to_h { |template| [template.fetch("name"), template] }
assert(by_name.length == templates.length, "template names are not unique")

tasks = by_name.fetch("main").dig("dag", "tasks")
assert(tasks.map { |task| task.fetch("name") }.uniq.length == tasks.length, "task names are not unique")
tasks.each do |task|
  target = by_name[task.fetch("template")]
  assert(target, "task #{task['name']} references missing template #{task['template']}")
  expected = target.fetch("inputs", {}).fetch("parameters", []).map { |parameter| parameter.fetch("name") }.sort
  actual = task.fetch("arguments", {}).fetch("parameters", []).map { |parameter| parameter.fetch("name") }.sort
  assert(expected == actual, "task #{task['name']} arguments #{actual} do not match inputs #{expected}")
end

volume_names = yaml.fetch("spec").fetch("volumes").map { |volume| volume.fetch("name") }
volume_names += yaml.fetch("spec").fetch("volumeClaimTemplates").map { |volume| volume.dig("metadata", "name") }
templates.each do |template|
  next unless template["script"]
  source = template.dig("script", "source")
  assert(source.include?("set -euo pipefail"), "#{template['name']} does not use set -euo pipefail")
  image = template.dig("script", "image")
  assert(image.include?("@sha256:") && !image.include?(":latest"), "#{template['name']} image is not digest pinned")
  template.dig("script", "volumeMounts")&.each do |mount|
    assert(volume_names.include?(mount.fetch("name")), "#{template['name']} mounts undefined volume #{mount['name']}")
  end
end

secret_yaml = YAML.safe_load(File.read("secrets.yaml"), aliases: true)
secret_json = JSON.parse(File.read("secrets.json"))
assert(secret_yaml == secret_json, "Secret YAML and JSON differ")

config_yaml = YAML.safe_load(File.read("nexus-concurrency-limit.yaml"), aliases: true)
config_json = JSON.parse(File.read("nexus-concurrency-limit.json"))
assert(config_yaml == config_json, "ConfigMap YAML and JSON differ")

puts "OK: YAML/JSON parity, task/template inputs, volumes, shell safety, and image pinning verified"
