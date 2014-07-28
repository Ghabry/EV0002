#
# This cinch plugin is part of EV0002
#
# written by carstene1ns <dev @ f4ke . de> 2014
# available under MIT license
#

# needs json gem
require "json"

class Cinch::GitHubWebhooks
  include Cinch::Plugin
  extend Cinch::HttpServer::Verbs

  post "/github_webhook" do
    request.body.rewind
    payload = request.body.read

    # check X-Hub-Signature, to ensure authorization
    secret = bot.config.plugins.options[Cinch::GitHubWebhooks][:secret]
    signature = 'sha1=' + OpenSSL::HMAC.hexdigest(OpenSSL::Digest.new('sha1'), secret, payload)
    halt 403 unless Rack::Utils.secure_compare(signature, request.env['HTTP_X_HUB_SIGNATURE'])

    # return if we got an x-www-form-urlencoded request
    halt 400 if params[:payload]

    # return if we got no valid json data
    data = JSON.parse(payload)
    halt 400 if data.empty?

    # get event type from http header
    event = request.env["HTTP_X_GITHUB_EVENT"]

    # we ignore some events
    halt 204 if [
                  'ping',               # test, when enabling webhook
                  'gollum',             # wiki changes
                  'deployment',         # ?
                  'deployment_status',  # ?
                  'member',             # collaborator added
                  'page_build',         # github pages built
                  'public',             # repository visibility
                  'status',             # internal git commit events
                  'team_add'            # user added to team
                 ].include? event

    # get common info: affected repository and user
    repo = data["repository"]["name"]
    unless event == "push"
      user = data["sender"]["login"]
    end

    # handle event
    case event
    when "issues"
      # opened and closed issues

      template = "%s %s issue %i of %s: \"%s\" - %s"
      message = sprintf(template,
                        user,
                        data["action"],
                        data["issue"]["number"],
                        repo,
                        data["issue"]["title"],
                        data["issue"]["html_url"])

    when "issue_comment"
      # comments on issues

      template = "%s commented on issue %i of %s: \"%s\" - %s"
      message = sprintf(template,
                        user,
                        data["issue"]["number"],
                        repo,
                        data["issue"]["title"],
                        data["comment"]["html_url"])

      # add up to 80 characters of the comment, sans all whitespace
      comment = data["comment"]["body"].gsub(/\s+/,' ').strip
      message << "\n> " + comment[0, 80]
      message << "…" if comment.length > 80

    when "watch"
      # starring a repo means watching it

      template = "%s starred %s: %s"
      message = sprintf(template,
                        user,
                        repo,
                        data["sender"]["html_url"])

    when "push"
      # git commits

      # TODO: figure out, why this is not in the hash, as api only returns 20 commits max.
      if data["commits"].count == 0
        # abort when an empty commit is pushed (for example deleting a branch)
        halt 204
      elsif data["commits"].count == 1
        counter_s = "1 commit"
      elsif data["commits"].count < 20
        counter_s = data["commits"].count.to_s + " commits"
      else
        # all above 19
        counter_s = "some commits"
      end

      template = "%s pushed %s to %s: %s."
      message = sprintf(template,
                        data["pusher"]["name"],
                        counter_s,
                        repo,
                        data["compare"])

    when "fork"
      # new fork

      template = "%s forked %s: %s"
      message = sprintf(template,
                        user,
                        repo,
                        data["forkee"]["html_url"])

    when "pull_request"
      # pull request

      action = data["action"]
      if action == "synchronize"
        action = "updated"
      elsif action == "closed"
        if data["pull_request"]["merged"] == false
          action = "rejected"
        else
          action = "merged"
        end
      end

      template = "%s %s pull request %i of %s \"%s\": %s"
      message = sprintf(template,
                        user,
                        action,
                        data["number"],
                        repo,
                        data["pull_request"]["title"],
                        data["pull_request"]["html_url"])

    when "pull_request_review_comment"
      # comment on pull request

      template = "%s commented on pull request %i of %s \"%s\": %s"
      message = sprintf(template,
                        user,
                        data["pull_request"]["number"],
                        repo,
                        data["pull_request"]["title"],
                        data["comment"]["html_url"])

      # add up to 80 characters of the comment, sans all whitespace
      comment = data["comment"]["body"].gsub(/\s+/,' ').strip
      message << "\n> " + comment[0, 80]
      message << "…" if comment.length > 80

    when "commit_comment"
      # comment on commit

      template = "%s commented on a commit of %s: %s"
      message = sprintf(template,
                        user,
                        repo,
                        data["comment"]["html_url"])

      # add up to 80 characters of the comment, sans all whitespace
      comment = data["comment"]["body"].gsub(/\s+/,' ').strip
      message << "\n> " + comment[0, 80]
      message << "…" if comment.length > 80

    when "create"
      # add branch or tag

      template = "%s created %s \"%s\" at %s"
      message = sprintf(template,
                        user,
                        data["ref_type"],
                        data["ref"],
                        repo)

    when "delete"
      # remove branch or tag

      template = "%s deleted %s \"%s\" at %s"
      message = sprintf(template,
                        user,
                        data["ref_type"],
                        data["ref"],
                        repo)

    when "release"
      # created release

      unless data["release"]["name"].nil?
        release = "release \"#{data["release"]["name"]}\""
      else
        release = "a release"
      end

      template = "%s created %s at %s: %s"
      message = sprintf(template,
                        user,
                        release,
                        repo,
                        data["release"]["html_url"])

    else
      # something we do not know, yet

      message = "Unknown #{event} event for #{repo} repository, dumped JSON: #{data.inspect[0, 300]}..."

    end

    # output
    bot.channels[0].send("[GitHub] #{message}")

    204
  end

  # ignore GET requests
  get "/github_webhook" do
    204
  end

  # error on unsupported requests
  put "/github_webhook" do
    400
  end

  delete "/github_webhook" do
    400
  end

  patch "/github_webhook" do
    400
  end

end