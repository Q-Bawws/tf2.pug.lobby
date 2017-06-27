# encoding: UTF-8

# Copyright (C) 2011 by Olivier Matz
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
# THE SOFTWARE.

module Pickup

  require 'active_record'
  require 'cinch'
  require 'date'

  require './config.rb'

  ActiveRecord::Base.establish_connection({ :adapter => 'mysql', :host => $db_host, :database => $db_name, :username => $db_user, :password => $db_pass, :encoding => 'utf8' })

  require './player.rb'
  require './server.rb'
  require './channel.rb'
  require './game.rb'
  require './map.rb'
  require './compete.rb'
  require './mumble.rb'
  require './game_variant.rb'
  require './server_status_observer.rb'

  Date.class_eval do
    def to_datetime
      second = sec + Rational(usec, 10**6)
      offset = Rational(utc_offset, 60 * 60 * 24)
      DateTime.new(year, month, day, hour, min, seconds, offset)
    end
  end

  ServerStatusObserver.new

  bot = Cinch::Bot.new do
    helpers do
      def game_registration(m, gclass)
        return unless @games.has_key?(m.channel.to_s)

        unless m.user.authed?
          m.reply(m.user.nick + " is not authenticated with Q.")
          return
        end

        begin
          p = Player.find_or_create_by_authname(m.user.authname)
          p.user = m.user
          @games[m.channel.to_s].register_player(p, gclass)
          m.channel.topic=($topic_title_prefix + @games[m.channel.to_s].status)
        rescue
          m.reply("@#{m.user.nick} : #{$!.to_s}")
          puts $!.backtrace
        end
      end

      def game_unregistration(m)
        return unless @games.has_key?(m.channel.to_s) and m.user.authed?

        @games[m.channel.to_s].unregister_player(Player.find_or_create_by_authname(m.user.authname))
        m.channel.topic=($topic_title_prefix + @games[m.channel.to_s].status)
      end

      def global_game_unregistration(m)
        return unless m.user.authed?

        p = Player.find_or_create_by_authname(m.user.authname)
        @games.each do |chan, g|
          if g.unregister_player(p)
            g.set_channel_topic            
          end
        end
      end

      def reset_game(chan)
        game = Game.new
        game.game_variant = chan.game_variant
        game.channel = chan
        game.init_registration
        game.bot = self

        @games[chan.name] = game
        game
      end
    end

    configure do |c|
      c.server = $irc_host
      c.nick = $irc_nick
      c.channels = []

      @games = {}

      # Register all channels present in the database and initialize
      # their game object.
      Channel.all.each do |chan|
        c.channels.push(chan.name)
       reset_game(chan)
      end

      # Unlock all servers for safety
      Server.all.each do |s|
        s.unlock
      end
    end
    
    on :connect do |m|
      # Send authentification command on connect if one has been specified.
      if $irc_authentification_command.length > 0
        raw($irc_authentification_command)
      end
    end

    on :join do |m|
      if m.user.nick == $irc_nick and @games.has_key?(m.channel.to_s)
        # If this event is triggered for the bot itself, fetch all whois
        # informations from the users present in the channel.
        m.channel.users.each do |u|
          u[0].whois
        end

        # And initialize channel topic.
        m.channel.topic=($topic_title_prefix + @games[m.channel.to_s].status)
      else
        # Fetch the whois information from the user who just joined.
        m.user.whois unless m.user.authed?
      end
    end

    on :part do |m|
      game_unregistration(m)
    end

    on :quit do |m|
      global_game_unregistration(m)
    end

    on :message, /^!(leave|del|delete|quit)$/ do |m|
      game_unregistration(m)
    end

    on :message, /^!(ready|rdy)/ do |m, cmd|
      return unless @games.has_key?(m.channel.to_s) and m.user.authed?

      begin
        @games[m.channel.to_s].register_ready(Player.find_or_create_by_authname(m.user.authname))
      rescue
        m.reply("@#{m.user.nick} : #{$!.to_s}")
        puts $!.backtrace
      end
    end

    on :message, /^!status/ do |m|
      return unless @games.has_key?(m.channel.to_s) and m.user.authed?

      m.reply(@games[m.channel.to_s].status)
    end

    on :message, /^!maps$/ do |m|
      return unless @games.has_key?(m.channel.to_s)

      m.reply(@games[m.channel.to_s].map_list)
    end

    on :message, /^!maps -d$/ do |m|
      return unless @games.has_key?(m.channel.to_s)

      m.user.send(@games[m.channel.to_s].map_list_url)
    end

#    on :message, /^!banstatus/ do |m|
#      return unless m.user.authed?
#
#      p = Player.find_or_create_by_authname(m.user.authname)
#      if p.banned?
#        m.reply("@#{m.user.nick}: 0,1You are banned until #{p.banned_until.to_s}#{p.ban_reason.nil? ? "" : " :#{p.ban_reason}"}")
#      else
#        m.reply("@#{m.user.nick}: 0,1You are not banned")
#      end
#    end

    on :message, /^!mumble/ do |m|
      return unless m.user.authed?

      msg = "0,1The Mumble server is: mumble.lethal-zone.eu"
#      Mumble.all.each do |mu|
#        msg += "0,1Serveur mumble #{mu.hostname}:#{mu.port.to_s} (mot de passe : #{mu.password})\n"
#      end
      m.reply(msg)
    end
	
    on :message, /^!help/ do |m|
      return unless m.user.authed?
      msg = "0,1The avaliable commands are: !<class>, !remove(!delete), !status, !maps (-d), !mumble, !map, !last"
      m.reply(msg)
    end

#    on :message, /^!reset/ do |m|
#    end

    on :message, /^!(map|vote|v) ([^ ]+)/ do |m, cmd, map|
      return unless @games.has_key?(m.channel.to_s) and m.user.authed?

      p = Player.find_or_create_by_authname(m.user.authname)

      begin
        name = @games[m.channel.to_s].register_vote(p, map)
        m.reply("@#{m.user.nick} : 0,1Voted for (#{name})")
      rescue
        m.reply("@#{m.user.nick} : 0,1#{$!.to_s}")
        puts $!.backtrace
      end
    end

    on :message, /^!accept/ do |m|
      Player.find_or_create_by_authname(m.user.authname).accept_terms_of_use
    end

    on :message, /^!servers/ do |m|
      return unless @games.has_key?(m.channel.to_s) and m.user.authed?

      msg = ""
      @games[m.channel.to_s].game_variant.servers.each do |s|
        if s.active?
          msg += "#{s.ip_address}:#{s.port} "
          if s.available?
            msg += "0,1(#{s.number_of_players} players at the moment)\n"
          else
            msg += "0,1(unavailable)\n"
          end
        end
      end

      m.reply(msg)
    end

    on :message, /^!last$/ do |m|
      return unless @games.has_key?(m.channel.to_s) and m.user.authed?

      m.reply("0,1Last pickup: " + @games[m.channel.to_s].channel.games.last.to_s)
    end

    on :message, /^!last -v$/ do |m|
      return unless @games.has_key?(m.channel.to_s) and m.user.authed?

      m.user.send("0,1Lasp pickup: " + @games[m.channel.to_s].channel.games.last.to_s_verbose)
    end

    on :message, /^!mylast$/ do |m|
      return unless m.user.authed?

      p = Player.find_or_create_by_authname(m.user.authname)

      if p.games.any?
        m.reply("0,1Last pickup: " + p.games.last.to_s)
      end
    end

    on :message, /^!mylast -v$/ do |m|
      return unless @games.has_key?(m.channel.to_s) and m.user.authed?

      p = Player.find_or_create_by_authname(m.user.authname)

      if p.games.any?
        m.user.send("0,1Last pickup: " + p.games.last.to_s_verbose)
      end
    end

    on :message, /^!pickup ([0-9]+)/ do |m, id|
      return unless m.user.authed?

      game = Game.find(id.to_i)
      if game.nil?
        m.reply("@#{m.user.nick}: 0,1can't find that pickup.")
      else
        m.reply(game.to_s)
      end
    end

    on :message, /^!(dem|demo|demoman)$/ do |m|
      game_registration(m, "demoman")
    end

    on :message, /^!(inge|engi|engineer)$/ do |m|
      game_registration(m, "engineer")
    end

    on :message, /^!(heavy|hwg)$/ do |m|
      game_registration(m, "heavy")
    end

    on :message, /^!(med|medic)$/ do |m|
      game_registration(m, "medic")
    end

    on :message, /^!pyro$/ do |m|
      game_registration(m, "pyro")
    end

    on :message, /^!(sc|scout)$/ do |m|
      game_registration(m, "scout")
    end

    on :message, /^!(snipe|sniper)$/ do |m|
      game_registration(m, "sniper")
    end

    on :message, /^!(sol|solly|soldier)$/ do |m|
      game_registration(m, "soldier")
    end

    on :message, /^!spy$/ do |m|
      game_registration(m, "spy")
    end

    on :message, /^!ban (.*)$/ do |m, args|
      return unless m.user.authed?

      p = Player.find_or_create_by_authname(m.user.authname)

      unless p.admin?
        m.reply("0,1Only admins can use that command.")
        return
      end

      re = Regexp.new("([^ ]+) ([0-9]+)(.*)")
      parsedargs = re.match(args)

      if parsedargs.nil?
        m.reply("0,1Invalid format of command (!ban <nick> <number of days> <reason>)")
        return
      end

      user = User(parsedargs[1])

      if user.nil? or not user.authed?
        m.reply("8,1@#{m.user.nick}: 0,1No auth user with that nick #{parsedargs[1]}.")
      else
        banned_p = Player.find_or_create_by_authname(user.authname)
        banned_p.ban(parsedargs[2].to_i, parsedargs[3])
        @games.each do |chan, g|
          if g.unregister_player(banned_p)
            g.set_channel_topic            
          end
        end
      end
    end

    on :message, /^!unlock ([0-9]+)/ do |m, id|
      return unless m.user.authed?

      p = Player.find_or_create_by_authname(m.user.authname)

      if not p.admin?
        m.reply("0,1Only admins can use that command.")
        return
      end

      Server.find(id.to_i).unlock
    end

    on :message, /^!reset/ do |m|
      return unless m.user.authed?

      p = Player.find_or_create_by_authname(m.user.authname)

      if not p.admin?
        m.reply("0,1COnly admins can use that command.")
        return
      end

      chan = Channel.find_by_name(m.channel.to_s)
      unless chan.nil?
        unless @games[m.channel.to_s].server.nil?
          @games[m.channel.to_s].server.unlock
        end
        reset_game(Channel.find_by_name(m.channel.to_s))
        @games[m.channel.to_s].set_channel_topic
      end
    end

    on :message, /^!unban ([^ ]+)/ do |m, nick|
      return unless m.user.authed?

      p = Player.find_or_create_by_authname(m.user.authname)

      if p.admin?
        if User(nick).nil? or not User(nick).authed?
          m.reply("8,1@#{m.user.nick}: 0,1No user with that nickname #{nick}.")
        else
          banned_p = Player.find_or_create_by_authname(User(nick).authname)
          banned_p.unban
        end
      end
    end

  end

  bot.start

end
