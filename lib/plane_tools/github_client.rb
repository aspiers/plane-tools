# frozen_string_literal: true

module PlaneTools
  # Thin wrapper around Octokit + two Faraday connections for
  # downloading user-attachment images.
  class GithubClient
    attr_reader :octokit, :auth_dl, :plain_dl

    def initialize(token:)
      @token = token
      @octokit = Octokit::Client.new(access_token: token, auto_paginate: true)

      # Faraday connection for downloading GH-hosted images. Auth header is
      # attached only here (NOT on any subsequent S3 fetch) so the token is
      # never forwarded across the github.com -> S3 redirect.
      @auth_dl = Faraday.new do |f|
        f.request :authorization, "token", token
        f.request :retry, max: 3, interval: 0.5, backoff_factor: 2,
                          retry_statuses: [429, 502, 503, 504]
        f.headers["User-Agent"] = "plane-tools"
      end

      # Bare connection for fetching S3 (no auth header — the presigned URL
      # already carries its own signature in the query string).
      @plain_dl = Faraday.new do |f|
        f.request :retry, max: 3, interval: 0.5, backoff_factor: 2,
                          retry_statuses: [429, 502, 503, 504]
        f.headers["User-Agent"] = "plane-tools"
      end
    end

    def issue(repo, num)
      @octokit.issue(repo, num)
    end

    def issue_comments(repo, num)
      @octokit.issue_comments(repo, num)
    end
  end
end
