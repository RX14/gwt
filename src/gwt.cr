require "colorize"
require "uri"
require "http"
require "json"

module GWT
  VERSION = "0.1.0"

  def self.run(args = ARGV)
    subcommand = args.shift?

    case subcommand
    when "clone"
      clone_args, other_args = args.partition { |arg| arg.starts_with? '-' }

      case other_args.size
      when 2
        url, base_path = other_args
      when 1
        url = other_args.first
        base_path = Path.posix(URI.parse(url).path).basename
      else
        raise "unknown args, expected URL, with optional path"
      end

      clone(base_path, url, clone_args)
    when "branch", "b"
      raise "unknown args, expected branch name" unless args.size == 1

      branch(args.first)
    when "feature", "f"
      raise "unknown args, expected feature branch name" unless args.size == 1

      branch("#{branch_prefix}feature/#{args.first}")
    when "bugfix", "bug"
      raise "unknown args, expected bugfix branch name" unless args.size == 1

      branch("#{branch_prefix}bugfix/#{args.first}")
    when "pr"
      raise "unknown args, expected PR url" unless args.size == 1

      pr(args.first)
    when "ls"
      ls
    when "on"
      raise "unknown args, expected branch qualifier and name" unless args.size >= 2
      branch_qualifier, branch_name = args.shift(2)

      case branch_qualifier
      when "branch", "b"
        # do nothing
      when "feature", "f"
        branch_name = "#{branch_prefix}feature/#{branch_name}"
      when "bugfix", "bug"
        branch_name = "#{branch_prefix}bugfix/#{branch_name}"
      end

      commandline = args

      on(branch_name, commandline)
    else
      raise "subcommands: clone, branch, feature, bugfix, pr, ls, on"
    end
  rescue ex : GWT::Error
    STDERR << "Error".colorize.red << ": #{ex.message}\n"
    exit 1
  end

  def self.clone(base_path, url, clone_args)
    clone_dir = "#{base_path}/main"

    git_args = ["clone"]
    git_args += clone_args
    git_args << url
    git_args << clone_dir

    command("git", git_args)

    default_branch = command_output("git", ["symbolic-ref", "--short", "HEAD"], chdir: clone_dir)
    File.rename(clone_dir, "#{base_path}/#{default_branch}")

    File.touch("#{base_path}/.gwt-root")
  end

  def self.branch(branch_name) : Nil
    target_dir = "#{root_dir}/#{branch_name}"

    unless Dir.exists?(target_dir)
      command("git", ["worktree", "add", "-b", branch_name, target_dir])
      copy_files(target_dir)
    end

    puts target_dir
  end

  def self.copy_files(target_dir)
    return unless File.exists?("#{root_dir}/.gwt-copy")

    copied_files = File.read_lines("#{root_dir}/.gwt-copy")

    source_dir = Path.new(command_output("git", ["rev-parse", "--show-toplevel"]))

    copied_files.each do |filename|
      File.copy(source_dir/filename, "#{target_dir}/#{filename}")
    end
  end

  def self.ls
    command("git", ["worktree", "prune"])

    root_dir = self.root_dir + "/"
    command_output("git", ["worktree", "list"]).each_line do |line|
      STDERR.puts line.lchop(root_dir)
    end
  end

  def self.on(branch_name, commandline)
    branch_dir = "#{root_dir}/#{branch_name}"

    command = commandline.shift
    args = commandline

    status = command(command, args, chdir: branch_dir, allow_failure: true)
    exit status.exit_code
  end

  def self.pr(pull_request_url)
    path = URI.parse(pull_request_url).path
    raise "no path on PR URL!" unless path

    path_parts = path.lchop('/').split('/')
    raise "couldn't parse PR path: expected 4 parts" unless path_parts.size >= 4
    user, repo, issue_type, issue_number = path_parts
    raise "couldn't parse PR path: expected PR" unless issue_type == "pull"

    issue_number = issue_number.to_i?
    raise "couldn't parse PR path: PR number was not numeric" unless issue_number

    headers = HTTP::Headers{"Accept" => "application/vnd.github.v3+json", "User-Agent" => "RX14/gwt #{VERSION} (language Crystal)"}
    response = HTTP::Client.get("https://api.github.com/repos/#{user}/#{repo}/pulls/#{issue_number}", headers: headers)

    content_type = response.content_type || ""
    raise "invalid content type #{content_type}" unless content_type.includes? "application/json"
    json = JSON.parse(response.body)

    raise "got #{response.status_code}: #{json["message"]}" unless response.success?

    author = json["user"]["login"].as_s
    title = slug(json["title"].as_s)
    branch_name = "pr/#{author}/#{issue_number}-#{title}"

    source_repo = json["head"]["repo"]
    source_repo_username = source_repo["owner"]["login"].as_s.downcase
    source_repo_clone_url = source_repo["clone_url"].as_s

    add_remote(source_repo_username, source_repo_clone_url)

    branch_dir = "#{root_dir}/#{branch_name}"
    branch_dir_exists = Dir.exists? branch_dir

    branch(branch_name)

    unless branch_dir_exists
      remote_ref = "#{source_repo_username}/#{json["head"]["ref"]}"
      command("git", ["fetch", source_repo_username], chdir: branch_dir)
      command("git", ["branch", "--set-upstream-to", remote_ref], chdir: branch_dir)
      command("git", ["reset", "--hard", remote_ref], chdir: branch_dir)
    end
  end

  def self.slug(string)
    string.gsub { |c| c.in_set?("A-Za-z0-9") ? c.downcase : '-' }.squeeze('-')
  end

  def self.add_remote(name : String, url : String)
    remote_list = command_output("git", ["remote", "-v"])
    remote_exists = false
    remote_list.each_line do |line|
      parts = line.split('\t')
      raise "unrecognised remote format" unless parts.size == 2
      remote_name, remote_url_base = parts

      remote_exists = true if remote_name == name
    end

    if remote_exists
      command("git", ["remote", "set-url", name, url])
    else
      command("git", ["remote", "add", name, url])
    end
  end

  def self.branch_prefix : String
    if File.exists?("#{root_dir}/.gwt-prefix")
      File.read("#{root_dir}/.gwt-prefix").chomp
    else
      ""
    end
  end

  def self.root_dir : String
    dir = Dir.current
    until File.exists? "#{dir}/.gwt-root"
      dir = File.expand_path("..", dir)

      raise "not in GWT root" if dir == "/"
    end

    dir
  end

  def self.command_output(command : String, args = nil,
                          env : Process::Env = nil, clear_env : Bool = false,
                          shell : Bool = false,
                          input : Process::Stdio = Process::Redirect::Close, error : Process::Stdio = Process::Redirect::Inherit,
                          chdir : String? = nil,
                          allow_failure : Bool = false)
    String.build do |str|
      command(command, args, env, clear_env, shell, input, str, error, chdir, allow_failure)
    end.chomp
  end

  def self.command(command : String, args = nil,
                   env : Process::Env = nil, clear_env : Bool = false,
                   shell : Bool = false,
                   input : Process::Stdio = Process::Redirect::Inherit, output : Process::Stdio = STDERR, error : Process::Stdio = Process::Redirect::Inherit,
                   chdir : String? = nil,
                   allow_failure : Bool = false) : Process::Status
    STDERR << "Running".colorize.blue << ": #{command} #{args.inspect}\n"

    status = Process.run(command, args, env, clear_env, shell, input, output, error, chdir)
    raise "Command failed! Exit code #{status.exit_code}" unless allow_failure || status.success?

    status
  end

  class Error < Exception
  end

  def self.raise(message)
    ::raise GWT::Error.new(message)
  end
end
