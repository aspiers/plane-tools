# frozen_string_literal: true

# Umbrella loader for plane-tools.
#
# Requires the library modules in dependency order. Bin scripts
# require this single file and then drive the CLI via
# PlaneTools::CLI.run.

require "bundler/setup"
require "dotenv"
require "octokit"
require "faraday"
require "faraday/retry"
require "commonmarker"
require "yaml"
require "optparse"
require "json"
require "logger"
require "fileutils"
require "securerandom"
require "uri"

module PlaneTools
end

require_relative "plane_tools/config"
require_relative "plane_tools/logging"
require_relative "plane_tools/plane_client"
require_relative "plane_tools/github_client"
require_relative "plane_tools/gh_renderer"
require_relative "plane_tools/attachments"
require_relative "plane_tools/image_rewriter"
require_relative "plane_tools/comments_syncer"
require_relative "plane_tools/cli"
