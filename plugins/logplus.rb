# -*- coding: utf-8 -*-
#
# = Cinch advanced message logging plugin
# Fully-featured logging module for cinch with HTML logs.
#
# == Configuration
# Add the following to your bot’s configure.do stanza:
#
#   config.plugins.options[Cinch::LogPlus] = {
#     :logdir => "/tmp/logs/htmllogs", # required
#     :logurl => "http://localhost/" # required
#   }
#
# [logdir]
#   This required option specifies where the HTML logfiles
#   are kept.
#
# == Author
# Marvin Gülker (Quintus)
# modified by carstene1ns
#
# == License
# An advanced logging plugin for Cinch.
# Copyright © 2014 Marvin Gülker
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Lesser General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

require "cgi"
require "time"
require "chronic"

# Cinch’s :channel event does not include messages Cinch sent itself.
# Especially for logging this is really bad, because the messages sent
# by the bot wouldn’t show up in the generated logfiles. Therefore, this
# monkeypatch adds a new :outmsg event to Cinch that is fired each time
# a PRIVMSG or NOTICE is issued by the bot. It takes the following
# arguments:
#
# [msg]
#   Always nil, this did not come from the IRC server.
# [text]
#   The message we are about to send.
# [notice]
#   If true, the message is a NOTICE. Otherwise, it's a PRIVMSG.
# [privatemsg]
#   If true, the message is to be sent directly to a user rather
#   than to a public channel.
class Cinch::Target

  # Override Cinch’s default message sending so so have an event
  # to listen for for our own outgoing messages.
  alias old_msg msg
  def msg(text, notice = false)
    @bot.handlers.dispatch(:outmsg, nil, text, notice, self.kind_of?(Cinch::User))
    old_msg(text, notice)
  end

end

class Cinch::LogPlus
  include Cinch::Plugin

  set :required_options, [:logdir]

  listen_to :connect,    :method => :startup
  listen_to :channel,    :method => :log_public_message
  listen_to :outmsg,     :method => :log_own_message
  listen_to :topic,      :method => :log_topic
  listen_to :join,       :method => :log_join
  listen_to :leaving,    :method => :log_leaving
  listen_to :nick,       :method => :log_nick
  listen_to :mode_change,:method => :log_modechange
  timer 60,              :method => :check_midnight

  match /log (.+)$/, method: :link_log
  match "log", method: :link_log_today

  # Default CSS used when the :extrahead option is not given.
  # Some default styling.
  DEFAULT_CSS = <<-EOC
    <style type="text/css">
      body {
        background: white;
        color: black;
        font: 0.9em "Droid Sans Mono", "DejaVu Sans Mono", "Bitstream Vera Sans Mono",
              "Liberation Mono", "Nimbus Mono L", Monaco, Consolas, "Lucida Console",
              "Lucida Sans Typewriter", "Courier New", monospace;
      }
      .chattable {
        border-collapse: collapse;
      }
      .msgnick {
        border-style: solid;
        border-color: #999;
        border-width: 0 1px;
        padding: 0 8px;
      }
      .msgtime {
        padding-right: 8px;
      }
      .msgtime a {
        text-decoration:none;
      }
      .msgmessage {
        padding-left: 8px;
        white-space: pre-wrap;
      }
      .msgaction {
        padding-left: 8px;
        font-style: italic;
      }
      .msgtopic {
        padding-left: 8px;
        font-weight: bold;
        font-style: italic;
        color: #920002;
      }
      .msgnickchange {
        padding-left: 8px;
        font-weight: bold;
        font-style: italic;
        color: #820002;
      }
      .msgmode {
        padding-left: 8px;
        font-weight: bold;
        font-style: italic;
        color: #920002;
      }
      .msgjoin {
        padding-left: 8px;
        font-style: italic;
        color: green;
      }
      .msgleave {
        padding-left: 8px;
        font-style: italic;
        color: red;
      }
    </style>
  EOC

  # Called on connect, sets up everything.
  def startup(*)
    @htmllogdir  = config[:logdir]
    @timelogformat = "%H:%M:%S"
    @extrahead = DEFAULT_CSS

    @last_time_check = Time.now
    @htmllogfile     = nil

    @filemutex = Mutex.new

    reopen_logs

    # Disconnect event is not always issued, so we just use
    # Ruby’s own at_exit hook for cleanup.
    at_exit do
      @filemutex.synchronize do
        @htmllogfile.close
      end
    end
  end

  # Timer target. Creates new logfiles if midnight has been crossed.
  def check_midnight
    time = Time.now

    # If day changed, finish this day’s logfiles and start new ones.
    reopen_logs unless @last_time_check.day == time.day

    @last_time_check = time
  end

  def link_log_today(msg)
    self.link_log(msg, "today")
  end

  def link_log(msg, sometime)
    # throw whatever time spec the user wanted at chronic gem
    requested_date = Chronic.parse(sometime, :context => :past)

    if requested_date.nil?
      msg.reply "I really have no idea which logfile you want…"
    else
      msg.reply "#{config[:logurl]}/#{requested_date.strftime('%Y-%m-%d')}.html"
    end
  end

  # Target for all public channel messages/actions not issued by the bot.
  def log_public_message(msg)
    @filemutex.synchronize do
      if msg.action?
        # Logs the given action to the HTML logfile Does NOT
        # acquire the file mutex!
        str = <<-HTML
          <tr id="#{timestamp_anchor(msg.time)}">
            <td class="msgtime">#{timestamp_link(msg.time)}</td>
            <td class="msgnick">*</td>
            <td class="msgaction"><span class="actionnick">#{determine_status(msg)}#{msg.user.name}</span>&nbsp;#{CGI.escape_html(msg.action_message)}</td>
          </tr>
        HTML
      else
        # Logs the given message to the HTML logfile.
        # Does NOT acquire the file mutex!
        str = <<-HTML
          <tr id="#{timestamp_anchor(msg.time)}">
            <td class="msgtime">#{timestamp_link(msg.time)}</td>
            <td class="msgnick">#{determine_status(msg)}#{msg.user}</td>
            <td class="msgmessage">#{CGI.escape_html(msg.message)}</td>
          </tr>
        HTML
      end
      @htmllogfile.write(str)
    end
  end

  # Target for all messages issued by the bot.
  def log_own_message(msg, text, is_notice, is_private)
    return if is_private # Do not log messages not targetted at the channel

    @filemutex.synchronize do
      # Logs the given text to the HTML logfile. Does NOT
      # acquire the file mutex!
      time = Time.now
      @htmllogfile.puts(<<-HTML)
        <tr id="#{timestamp_anchor(time)}">
          <td class="msgtime">#{timestamp_link(time)}</td>
          <td class="msgnick">:#{bot.nick}</td>
          <td class="msgmessage">#{CGI.escape_html(text)}</td>
        </tr>
      HTML
    end
  end

  # Target for /topic commands.
  def log_topic(msg)
    @filemutex.synchronize do
      # Logs the given topic change to the HTML logfile. Does NOT
      # acquire the file mutex!
      @htmllogfile.write(<<-HTML)
        <tr id="#{timestamp_anchor(msg.time)}">
          <td class="msgtime">#{timestamp_link(msg.time)}</td>
          <td class="msgnick">*</td>
          <td class="msgtopic"><span class="actionnick">#{determine_status(msg)}#{msg.user.name}</span>&nbsp;changed the topic to “#{CGI.escape_html(msg.message)}”.</td>
        </tr>
      HTML
    end
  end

  def log_nick(msg)
    @filemutex.synchronize do
      oldnick = msg.raw.match(/^:(.*?)!/)[1]
      @htmllogfile.write(<<-HTML)
        <tr id="#{timestamp_anchor(msg.time)}">
          <td class="msgtime">#{timestamp_link(msg.time)}</td>
          <td class="msgnick">--</td>
          <td class="msgnickchange"><span class="actionnick">#{determine_status(msg, oldnick)}#{oldnick}</span>&nbsp;is now known as <span class="actionnick">#{determine_status(msg, msg.message)}#{msg.message}</span>.</td>
        </tr>
      HTML
    end
  end

  def log_join(msg)
    @filemutex.synchronize do
      @htmllogfile.write(<<-HTML)
        <tr id="#{timestamp_anchor(msg.time)}">
          <td class="msgtime">#{timestamp_link(msg.time)}</td>
          <td class="msgnick">--&gt;</td>
          <td class="msgjoin"><span class="actionnick">#{determine_status(msg)}#{msg.user.name}</span>&nbsp;entered #{msg.channel.name}.</td>
        </tr>
      HTML
    end
  end

  def log_leaving(msg, leaving_user)
    @filemutex.synchronize do
      if msg.channel?
        text = "left #{msg.channel.name} (#{CGI.escape_html(msg.message)})"
      else
        text = "left the IRC network (#{CGI.escape_html(msg.message)})"
      end

      @htmllogfile.write(<<-HTML)
        <tr id="#{timestamp_anchor(msg.time)}">
          <td class="msgtime">#{timestamp_link(msg.time)}</td>
          <td class="msgnick">&lt;--</td>
          <td class="msgleave"><span class="actionnick">#{determine_status(msg)}#{leaving_user.name}</span>&nbsp;#{text}.</td>
        </tr>
      HTML
    end
  end

  def log_modechange(msg, changes)
    @filemutex.synchronize do
      adds = changes.select{|subary| subary[0] == :add}
      removes = changes.select{|subary| subary[0] == :remove}

      change = ""
      unless removes.empty?
        change += removes.reduce("-"){|str, subary| str + subary[1] + (subary[2] ? " " + subary[2] : "")}.rstrip
      end
      unless adds.empty?
        change += adds.reduce("+"){|str, subary| str + subary[1] + (subary[2] ? " " + subary[2] : "")}.rstrip
      end

      @htmllogfile.write(<<-HTML)
        <tr id="#{timestamp_anchor(msg.time)}">
          <td class="msgtime">#{timestamp_link(msg.time)}</td>
          <td class="msgnick">--</td>
          <td class="msgmode">Mode #{change} by <span class="actionnick">#{determine_status(msg)}#{msg.user.name}</span>.</td>
        </tr>
      HTML
    end
  end

  private

  # Helper method for generating the file basename for the logfiles
  # and appending the given extension (which must include the dot).
  def genfilename(ext)
    Time.now.strftime("%Y-%m-%d") + ext
  end

  # Helper method for determining the status of the user sending
  # the message. Returns one of the following strings:
  # "opped", "halfopped", "voiced", "".
  def determine_status(msg, user = msg.user)
    return "" unless msg.channel # This is nil for leaving users
    return "" unless user # server-side NOTICEs

    user = user.name if user.kind_of?(Cinch::User)

    if user == bot.nick
      ":"
    elsif msg.channel.opped?(user)
      "@"
    elsif msg.channel.half_opped?(user)
      "%"
    elsif msg.channel.voiced?(user)
      "+"
    else
      ""
    end
  end

  # Finish a day’s logfiles and open new ones.
  def reopen_logs
    @filemutex.synchronize do
      #### HTML log file ####

      # If the bot was restarted, an HTML logfile already exists.
      # We want to continue that one rather than overwrite.
      htmlfile = File.join(@htmllogdir, genfilename(".html"))
      if @htmllogfile
        if File.exist?(htmlfile)
          # This shouldn’t happen (would be a useless call of reopen_logs)
          # nothing, continue using current file
        else
          # Normal midnight log rotation
          finish_html_file
          @htmllogfile.close

          @htmllogfile = File.open(htmlfile, "w")
          @htmllogfile.sync = true
          start_html_file
        end
      else
        if File.exist?(htmlfile)
          # Bot restart on the same day
          @htmllogfile = File.open(htmlfile, "a")
          @htmllogfile.sync = true
          # Do not write preamble, continue with current file
        else
          # First bot startup on this day
          @htmllogfile = File.open(htmlfile, "w")
          @htmllogfile.sync = true
          start_html_file
        end
      end
    end

    bot.info("Opened new logfiles.")
  end

  def timestamp_anchor(time)
    "msg-#{time.strftime("%H:%M:%S")}"
  end

  def timestamp_link(time)
    "<a href=\"#msg-#{time.strftime("%H:%M:%S")}\">#{time.strftime(@timelogformat)}</a>"
  end

  # Write the start bloat HTML to the HTML log file.
  # Does NOT acquire the file mutex!
  def start_html_file
    @htmllogfile.puts <<-HTML
<!DOCTYPE HTML>
<html>
  <head>
    <title>#{bot.config.channels.first} IRC logs, #{Time.now.strftime('%Y-%m-%d')}</title>
    <meta charset="utf-8"/>
#{@extrahead}
  </head>
  <body>
    <h1>#{bot.config.channels.first} IRC logs, #{Time.now.strftime('%Y-%m-%d')}</h1>
    <p>
      All times are UTC#{Time.now.strftime('%:z')}.
      <a href="#{Date.today.prev_day.strftime('%Y-%m-%d')}.html">&lt;==</a>
      <a href="#{Date.today.next_day.strftime('%Y-%m-%d')}.html">==&gt;</a>
    </p>
    <hr/>
    <table class="chattable">
    HTML
  end

  # Write the end bloat to the HTML log file.
  # Does NOT acquire the file mutex!
  def finish_html_file
    @htmllogfile.puts <<-HTML
    </table>
  </body>
</html>
    HTML
  end

end
