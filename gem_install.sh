#!/bin/sh
# vim: set sw=2 sts=2 et tw=80 ft=ruby:
=begin &>/dev/null
# workaround for rubinius bug
# https://github.com/rubinius/rubinius/issues/2732
export LC_ALL="en_US.UTF-8"
export LANG="en_US.UTF-8"
shopt -s nullglob
for ruby in $(/usr/bin/ruby-find-versioned) ; do
  $ruby -x $0 "$@"
done
exit $?
=end
#!/usr/bin/ruby
#require 'gem2rpm'
require 'rbconfig'
require 'optparse'
require 'optparse/time'
require 'ostruct'
require 'fileutils'
require 'find'
require 'tempfile'
require 'logger'

require 'rubygems/package'

options=OpenStruct.new
options.defaultgem=nil
options.gemfile=nil
options.otheropts=nil
options.buildroot=nil
options.docfiles=[]
options.gemname=nil
options.gemversion=nil
options.gemsuffix=nil
options.otheropts=[]
options.ua_dir='/etc/alternatives'
options.docdir='/usr/share/doc/packages'
# once we start fixing packages set this to true
options.symlinkbinaries=false
options.verbose = false
options.rpmsourcedir = ENV['RPM_SOURCE_DIR'] || '/home/abuild/rpmbuild/SOURCES'
options.rpmbuildroot = ENV['RPM_BUILD_ROOT'] || '/home/abuild/rpmbuild/BUILDROOT/just-testing'

GILogger = Logger.new(STDERR)
GILogger.level=Logger::DEBUG
def bail_out(msg)
  GILogger.error(msg)
  exit 1
end

def patchfile(fname, needle, replace)
    tmpdir = File.dirname(fname)
    tmp = Tempfile.new('snapshot', tmpdir)
    begin
      stat = File.stat(fname)
      tmp.chmod(stat.mode)
      fc = File.read(fname)
      # fc.gsub!(/^(#!\s*.*?)(\s+-.*)?$/, "#!#{ruby} \2")
      fc.gsub!(needle, replace)
      tmp.write(fc)
      tmp.close
      File.rename(tmp, fname)
    rescue ArgumentError => ex
      GILogger.error "Exception while patching '#{fname}'. (#{ex}) Skipping ..."
    ensure
      tmp.close
    end
end

opt_parser = OptionParser.new do |opts|
  opts.banner = "Usage: gem_install.rb [options]"

  opts.separator ""
  opts.separator "Specific options:"

  opts.on('--config [FILENAME]', 'path to gem2rpm.yml') do |name|
    options.config = name
  end

  opts.on('--default-gem [FILENAME]', 'Which filename to use when we dont find another gem file.') do |fname|
    options.defaultgem=fname
  end
  opts.on('--gem-binary [PATH]', 'Path to gem. By default we loop over all gem binaries we find') do |fname|
    GILogger.warn ("The --gem-binary option is deprecated.")
  end
  opts.on('--doc-files [FILES]', 'Whitespace separated list of documentation files we should link to /usr/share/doc/packages/<subpackage>') do |files|
    options.docfiles = files.split(/\s+/)
  end
  opts.on('--gem-name [NAME]', 'Name of them gem') do |name|
    options.gemname = name
  end
  opts.on('--gem-version [VERSION]', 'Version of them gem') do |version|
    options.gemversion = version
  end
  opts.on('--gem-suffix [SUFFIX]', 'Suffix we should append to the subpackage names') do |suffix|
    options.gemsuffix = suffix
  end
  opts.on('--build-root [BUILDROOT]', 'Path to rpm buildroot') do |buildroot|
    options.buildroot = buildroot
  end
  # Boolean switches
  opts.on('--[no-]symlink-binaries', 'Create all the version symlinks for the binaries') do |v|
    options.symlinkbinaries = v
  end
  opts.on('-d', 'Forwarded to gem install') do |v|
    options.otheropts << '-d'
  end
  opts.on('-f', 'Forwarded to gem install') do |v|
    options.otheropts << '-f'
  end
  opts.on('-E', 'Forwarded to gem install') do |v|
    options.otheropts << '-E'
  end
  opts.on('--no-ri', 'Forwarded to gem install') do |v|
    options.otheropts << '--no-ri'
  end
  opts.on('--no-rdoc', 'Forwarded to gem install') do |v|
    options.otheropts << '--no-rdoc'
  end
  opts.separator ""
  opts.separator "Common options:"
  opts.on("-v", "--[no-]verbose", "Run verbosely") do |v|
    options.verbose = v
  end
  opts.on_tail('-h', '--help', 'Show this message') do
    puts opts
    exit
  end
end

options.otheropts+=opt_parser.parse!(ARGV)
GILogger.info "unhandled options: #{options.otheropts.inspect}"
if options.gemfile.nil?
  # we are in /home/abuild/rpmbuild/BUILD/
  # search for rebuild gem files
  gemlist = Dir['*/*.gem', '*/*/.gem', "#{options.rpmsourcedir}/*.gem"]
  if gemlist.empty?
     bail_out("Can not find any gem file")
  end
  options.gemfile = gemlist.first
  GILogger.info "Found gem #{options.gemfile}"
end

# TODO: we can *not* use gem2rpm here. check how to do it with plain rubygems.
package   = Gem::Package.new(options.gemfile)
spec      = package.spec
gemdir    = File.join(Gem.dir, 'gems', "#{options.gemname}-#{options.gemversion}")
# TODO: ruby = "#{File.join(RbConfig::CONFIG['bindir'],RbConfig::CONFIG['ruby_install_name'])}mo"
ruby      = Gem.ruby
gembinary = Gem.default_exec_format % "/usr/bin/gem"

rubysuffix = Gem.default_exec_format % ''
case rubysuffix
  when /\A\d+.\d+\z/
    options.rubysuffix = ".ruby#{rubysuffix}"
    options.rubyprefix = "ruby#{rubysuffix}"
  when /\A\.(.*)\z/
    options.rubysuffix = ".#{$1}"
    options.rubyprefix = $1
  when ''
    rb_ver = RbConfig::CONFIG['ruby_version'].gsub(/^(\d+\.\d+).*$/, "\1")
    options.rubysuffix = ".ruby#{rb_ver}"
    options.rubyprefix = "ruby#{rb_ver}"
  else
    bail_out "unknown binary naming scheme: #{rubysuffix}"
end
GILogger.info "Using prefix #{options.rubyprefix}"
GILogger.info "Using suffix #{options.rubysuffix}"

cmdline = [gembinary, 'install', '--verbose', '--local', '--build-root', options.buildroot]
cmdline += options.otheropts
cmdline << options.gemfile
GILogger.info "install cmdline: #{cmdline.inspect}"
system(cmdline.join(' '))

rpmname="#{options.rubyprefix}-rubygem-#{options.gemname}#{options.gemsuffix}"
GILogger.info "RPM name: #{rpmname}"
pwd = Dir.pwd
bindir = File.join(options.rpmbuildroot, Gem.bindir)
GILogger.info "bindir: #{bindir}"
if options.symlinkbinaries && File.exists?(bindir)
  br_ua_dir = File.join(options.rpmbuildroot, options.ua_dir)
  GILogger.info "Creating upate-alternatives dir: #{br_ua_dir}"
  FileUtils.mkdir_p(br_ua_dir)
  begin
    Dir.chdir(bindir)
    GILogger.info "executables: #{spec.executables.inspect}"
    spec.executables.each do |unversioned|
      default_path   = Gem.default_exec_format % unversioned
      full_versioned = "#{unversioned}#{options.rubysuffix}-#{spec.version}"
      ruby_versioned = "#{unversioned}#{options.rubysuffix}"
      gem_versioned  = "#{unversioned}-#{spec.version}"
      File.rename(default_path, full_versioned)
      patchfile(full_versioned,  />= 0/, "= #{options.gemversion}")
      # unversioned
      [unversioned, ruby_versioned, gem_versioned].each do |linkname|
        full_path = File.join(br_ua_dir, linkname)
        ua_path   = File.join(options.ua_dir, linkname)
        GILogger.info "Linking '#{linkname}' to '#{full_path}'"
        File.symlink(linkname, full_path) unless File.symlink? full_path
        GILogger.info "Linking '#{ua_path}' to '#{linkname}'"
        File.symlink(ua_path, linkname) unless File.symlink? linkname
      end
    end
  ensure
    Dir.chdir(pwd)
  end
end

# shebang line fix
Find.find(File.join(options.buildroot, gemdir)) do |fname|
  if File.file?(fname) && File.executable?(fname)
    next if fname =~ /\.so$/
    GILogger.info "Looking at #{fname}"
    patchfile(fname, /^(#!\s*.*?)(\s+-.*)?$/, "#!#{ruby} \2")
  else
    next
  end
end

unless options.docfiles.empty?
  GILogger.info "Linking documentation"
  docdir = File.join(options.rpmbuildroot, options.docdir, rpmname)
  FileUtils.mkdir_p(docdir)

  options.docfiles.each do |fname|
    fullpath = File.join(gemdir, fname)
    GILogger.info "- #{fullpath}"
    File.symlink(fullpath, File.join(docdir,fname))
  end
end

system("chmod -R u+w,go+rX,go-w #{options.rpmbuildroot}")
#system("find #{options.rpmbuildroot} -ls")
