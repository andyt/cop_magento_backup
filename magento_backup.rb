#!/usr/bin/ruby

###
# magento_backup.rb
# Backs up a magento instance to Amazon S3
#
# http://github.com/copious/magento_backup
#
# Copyright (c) 2011 by Copious
# All Rights Reserved
###

require 'yaml'
require 'rubygems'
require 'aws/s3'

### This backup script has a soundtrack:
#
# https://www.youtube.com/watch?v=pDcPBGESkAI
#
###

### Read the YAML configuration file
unless File.exists?('magento_backup.yml')
	puts "magento_backup.yml doesn't exist.  Please create it."
	exit 1
end
config = YAML::load_file('magento_backup.yml')

web_ssh_root = "#{config['webserver']['username']}@#{config['webserver']['hostname']}"
# web_ssh_root looks like: copious@sportswave.staging.copiousdev.com

db_ssh_root = "#{config['database']['ssh_username']}@#{config['database']['hostname']}"
# db_ssh_root looks like: copious@sportswave.staging.copiousdev.com

backup_name = "#{config['site_name']}_backup_#{Time.now.year}-#{Time.now.month}-#{Time.now.day}"
# backup_name looks like: sportswave_backup_2011-10-27

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

if File.exists?("#{backup_name}.tgz")
	puts "   - #{backup_name}.tgz already exists.  Skipping archive generation."

else

	### Make a backup of their uploaded assets
	print "   - backing up uploaded assets... " 
	asset_backup_command = "/usr/bin/scp -r \"#{web_ssh_root}:#{config['webserver']['media_path']}/*\" \"#{backup_name}/assets/\" > #{backup_name}/backup.log 2>&1"
	unless system(asset_backup_command)
		puts "Couldn't download assets from #{web_ssh_root}:#{config['webserver']['media_path']} to #{backup_name}/assets/.   Details in #{backup_name}/backup.log."
		exit 1
	end
	puts "done."


	### Put up the maintenance notice
	print "   - putting up maintenance notice... "
	maintenance_notice_command = "/usr/bin/ssh \"#{web_ssh_root}\" \"touch #{config['webserver']['app_root']}/maintenance.flag\" 2>#{backup_name}/backup.log"
	unless system(maintenance_notice_command)
		puts "Couldn't put up a maintenance notice.  Details in #{backup_name}/backup.log."
		exit 1
	end
	puts "done."


	### Make a backup of their database
	print "   - backing up database... "
	escaped_password = config['database']['password']
	escaped_password.gsub!('!','\\!')
	escaped_password.gsub!('$','\\\\\\\\\\$')  ### Yo dawg, I heard you like interpolation.
	database_backup_command = "/usr/bin/ssh \"#{db_ssh_root}\" \"/usr/bin/mysqldump -u #{config['database']['db_username']} --password=#{escaped_password} #{config['database']['database']}\" > #{backup_name}/database/#{config['database']['database']}.sql 2>#{backup_name}/backup.log"
	unless system(database_backup_command)
		puts "Couldn't make a backup of the current database.  Details in #{backup_name}/backup.log."
		exit 1
	end
	puts "done."


	### Remove the maintenance notice
	print "   - removing maintenance notice... "
	remove_maintenance_notice_command = "/usr/bin/ssh \"#{web_ssh_root}\" \"rm #{config['webserver']['app_root']}/maintenance.flag\" 2>#{backup_name}/backup.log"
	unless system(remove_maintenance_notice_command)
		puts "Couldn't remove maintenance notice.  Details in #{backup_name}/backup.log."
		exit 1
	end

	puts "done."


	### Tar those backups together
	print "   - compressing backup... "
	compress_backup_command = "/bin/tar zcf #{backup_name}.tgz #{backup_name}/*"
	if system(compress_backup_command)
		unless system("rm -rf #{backup_name}")
			puts "Couldn't remove pre-archival data.  Exiting."
			exit 1
		end
	else
		puts "Couldn't compress the backup in #{backup_name}.  Exiting."
		exit 1
	end
	puts "done."

end

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
begin
	AWS::S3::S3Object.find("#{backup_name}.tgz", config['amazon']['bucket'])
	### If this succeeds, the backup already exists.

	puts "There is already a backup called #{backup_name} in the bucket #{config['amazon']['bucket']}.  Exiting."
	exit 1

rescue AWS::S3::NoSuchKey
	begin
		AWS::S3::S3Object.store("#{backup_name}.tgz", open("#{backup_name}.tgz"), config['amazon']['bucket'], :content_type => 'application/x-compressed', :access => :private)
	rescue Errno::ECONNRESET
		puts "Connection reset by peer.\n\nUnable to push backiup file #{backup_name} to Amazon S3 due to a connection reset.  The fix for this is from <http://scie.nti.st/2008/3/14/amazon-s3-and-connection-reset-by-peer>:\nThis most likely means you're running on Linux kernel 2.6.17 or higher with a TCP buffer size too large for your equipment to understand.  To work around this issue, you will need to reconfigure your sysctl to decrease your maximum TCP window size.  Put the following in /etc/sysctl.conf:\n\n\t# Workaround for TCP Window Scaling bugs in other ppl's equipment:\n\tnet.ipv4.tcp_wmem = 4096 16384 512000\n\tnet.ipv4.tcp_rmem = 4096 87380 512000\n\nThen run:\n\n\t$ sudo sysctl -p\n\nThe last number in that group of three is the important one. If you’re not getting any resets, increase it and your uploads/downloads will be faster. If you are getting resets, decrease it and it’ll make the resets go away, but your throughput will be slower now."
	end
end
puts "done."


### Remove the local backup file
print "   - removing local copy of the backup... "
begin
	AWS::S3::S3Object.find("#{backup_name}.tgz", config['amazon']['bucket'])
	### If this succeeds, the backup file is there.

	if system("rm #{backup_name}.tgz")
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
