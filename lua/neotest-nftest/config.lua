---@class neotestNfTest.Config
---@field public profile string Profile to use when running tests. Defaults to "docker"
---@field public extra_args string[] Additional arguments to pass to nf-test when running tests
local Config = {
  profile = "docker",
  extra_args = {},
}

return Config
