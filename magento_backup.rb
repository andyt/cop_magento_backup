#!/usr/bin/ruby

###
# magento_backup.rb
# Backs up a magento instance to Amazon S3
#
# http://github.com/copious/magento_backup
#
# Copyright (c) 2011-2012 by Copious
#
# This software is available under the Academic Free License, version 3.0:
# http://www.opensource.org/licenses/afl-3.0.php
###

require 'bundler'
Bundler.setup()

require 'yaml'
require 'openssl'
require 'rubygems'
require 'aws/s3'
require 'optparse'

options = {
	:cleanup => true,
	:config_file => 'magento_backup.yml'
}

optparse = OptionParser.new do |opts|
	opts.banner = 'Usage: ruby magento_backup.rb [--no-cleanup] [--config FILE]'

	opts.on('-nc', '--no-cleanup', 'Do not delete local copies') do
		options[:cleanup] = false
	end

	opts.on('-c', '--config FILE', 'Full path to configuration yml file.') do |f|
		options[:config_file] = f
	end
end

### Read the YAML configuration file
unless File.exists?(options[:config_file])
	puts "\"#{options[:config_file]}\" doesn't exist.  Please create it."
	exit 1
end
config = YAML::load_file(options[:config_file])

web_ssh_root = "#{config['webserver']['username']}@#{config['webserver']['hostname']}"
# web_ssh_root looks like: copious@sportswave.staging.copiousdev.com

db_ssh_root = "#{config['database']['ssh_username']}@#{config['database']['hostname']}"
# db_ssh_root looks like: copious@sportswave.staging.copiousdev.com

backup_name = "#{config['site_name']}_backup_#{Time.now.year}-#{Time.now.month}-#{Time.now.day}"
# backup_name looks like: sportswave_backup_2011-10-27

tar_command = `which tar`.strip
ssh_command = `which ssh`.strip
nice_command = `which nice`.strip
rsync_command = `which rsync`.strip
split_command = `which split`.strip

puts "Creating backup #{backup_name}..."
unless system("mkdir -p #{backup_name}")
	print "Couldn't create backup directory at #{backup_name}"
	exit 1
end
unless system("mkdir -p #{backup_name}/assets/")
	print "Couldn't create assets backup directory at #{backup_name}/assets"
	exit 1
end
unless system("mkdir -p #{backup_name}/database/")
	print "Couldn't create database backup directory at #{backup_name}/database"
	exit 1
end

STDOUT.sync = true

if File.exists?("#{backup_name}.tgz.00")
	puts "   - #{backup_name}.tgz.00 already exists.  Skipping archive generation."

else

	### Make a backup of their uploaded assets
	print "   - backing up uploaded assets... " 
	asset_backup_command = "#{rsync_command} -av \"#{web_ssh_root}:#{config['webserver']['media_path']}/*\" \"#{backup_name}/assets/\" > #{backup_name}/backup.log 2>&1"
	unless system(asset_backup_command)
		puts "Couldn't download assets from #{web_ssh_root}:#{config['webserver']['media_path']} to #{backup_name}/assets/.   Details in #{backup_name}/backup.log."
		exit 1
	end
	puts "done."


	### Put up the maintenance notice
	print "   - putting up maintenance notice... "
	maintenance_notice_command = "#{ssh_command} \"#{web_ssh_root}\" \"touch #{config['webserver']['app_root']}/maintenance.flag\" 2>#{backup_name}/backup.log"
	unless system(maintenance_notice_command)
		puts "Couldn't put up a maintenance notice.  Details in #{backup_name}/backup.log."
		exit 1
	end
	puts "done."


	### Make a backup of their database
	print "   - backing up database... "
	escaped_password = config['database']['password']
	escaped_password.gsub!('!','\\!')
	escaped_password.gsub!('$','\\\\\\\\\\$')
	database_backup_command = "#{ssh_command} \"#{db_ssh_root}\" \"/usr/bin/mysqldump -u #{config['database']['db_username']} --password=#{escaped_password} #{config['database']['database']}\" > #{backup_name}/database/#{config['database']['database']}.sql 2>#{backup_name}/backup.log"
	unless system(database_backup_command)
		puts "Couldn't make a backup of the current database.  Details in #{backup_name}/backup.log."
		exit 1
	end
	puts "done."

	### Remove the maintenance notice
	print "   - removing maintenance notice... "
	remove_maintenance_notice_command = "#{ssh_command} \"#{web_ssh_root}\" \"rm #{config['webserver']['app_root']}/maintenance.flag\" 2>#{backup_name}/backup.log"
	unless system(remove_maintenance_notice_command)
		puts "Couldn't remove maintenance notice.  Details in #{backup_name}/backup.log."
		exit 1
	end

	puts "done."


	### Tar those backups together
	print "   - compressing backup... "
	compress_backup_command = "#{nice_command} #{tar_command} zcf #{backup_name}.tgz #{backup_name}/*"
	if system(compress_backup_command)
		if(options[:cleanup])
			unless system("rm -rf #{backup_name}")
		 		puts "Couldn't remove pre-archival data.  Exiting."
		 		exit 1
			end
		end
	else
		puts "Couldn't compress the backup in #{backup_name}.  Exiting."
		exit 1
	end
	puts "done."

	### Partition the backups into files that won't break AMZN S3
	print "   - splitting backups... "
	if RUBY_PLATFORM =~ /darwin/ # mac
		split_backups_command = "#{split_command} -b 1024m #{backup_name}.tgz #{backup_name}.tgz."
	else
		split_backups_command = "#{split_command} -b 1024M -d #{backup_name}.tgz #{backup_name}.tgz."
	end
	if system(split_backups_command)
		unless system("rm -rf #{backup_name}.tgz")
			puts "Couldn't remove unpartitioned data.  Exiting."
			exit 1
		end
	else
		puts "Couldn't partition the backup in #{backup_name}.  Exiting."
		exit 1
	end
	puts "done."

end
# Get a list of the generated files.
backup_file_list = Dir.glob("#{backup_name}\.tgz\.*")

### Upload the backup file to Amazon S3
print "   - uploading to amazon cloud... "
AWS::S3::Base.establish_connection!(
  :persistent        => false,
  :access_key_id     => config['amazon']['access_key_id'],
  :secret_access_key => config['amazon']['secret_access_key']
)
backups_bucket = AWS::S3::Bucket.find(config['amazon']['bucket'])
unless backups_bucket
	AWS::S3::Bucket.create(config['amazon']['bucket'])
	backups_bucket = AWS::S3::Bucket.find(config['amazon']['bucket'])
end

current_file = nil
begin
	# Check each file to see if it's uploaded
	backup_file_list.each do |file|
		current_file = file
		AWS::S3::S3Object.find(current_file, config['amazon']['bucket'])
		current_file = nil
	end
	### If this succeeds, the backup already exists.

	puts "There is already a backup called #{backup_name} in the bucket #{config['amazon']['bucket']}.  Exiting."
	exit 1

rescue AWS::S3::NoSuchKey
	files_to_upload = backup_file_list.clone

	# prune files_to_upload for each existing file
	if current_file # if this is not nil, an exception prevented it, indicating the file does not exist. This is the first file to upload.
		current_file_index = files_to_upload.index(current_file)

		files_to_upload = files_to_upload[current_file_index...(files_to_upload.length)]
	else
		# if current_file is nil, all backup files already exist. Exit and do nothing.
		puts "Backup files already uploaded. Exiting."
		exit 1
	end

	begin
		files_to_upload.each do |file|
			AWS::S3::S3Object.store(file, open(file), config['amazon']['bucket'], :content_type => 'application/x-compressed', :access => :private)
		end
	rescue Errno::ECONNRESET
		puts <<-END
Connection reset by peer.

Unable to push backup file #{backup_name} to Amazon S3 due to a connection reset.  The fix for this is from <http://scie.nti.st/2008/3/14/amazon-s3-and-connection-reset-by-peer>:
This most likely means you're running on Linux kernel 2.6.17 or higher with a TCP buffer size too large for your equipment to understand.  To work around this issue, you will need to reconfigure your sysctl to decrease your maximum TCP window size.  Put the following in /etc/sysctl.conf:
\t# Workaround for TCP Window Scaling bugs in other ppl's equipment:
\tnet.ipv4.tcp_wmem = 4096 16384 512000
\tnet.ipv4.tcp_rmem = 4096 87380 512000

Then run:
\t$ sudo sysctl -p

The last number in that group of three is the important one. If you're not getting any resets, increase it and your uploads/downloads will be faster. If you are getting resets, decrease it and it'll make the resets go away, but your throughput will be slower now.
		END

		exit 1
	end
end
puts "done."

### Remove the local backup file
print "   - removing local copy of the backup... "
begin
	if system("rm #{backup_name}.tgz*")
		puts "done."
	else
		puts "Couldn't unlink #{backup_name}.tgz. Exiting."
		exit 1
	end

rescue AWS::S3::NoSuchKey
	puts "Backup file couldn't be uploaded to Amazon S3. Exiting."
	exit 1
end

puts "done."
