#!/usr/bin/ruby

###
# magento_backup.rb
# Backs up a magento instance to Amazon S3
#
# http://github.com/copious/magento_backup
#
# Copyright (c) 2011-2013 by COPIOUS
#
# This software is available under the Academic Free License, version 3.0:
# http://www.opensource.org/licenses/afl-3.0.php
###

require 'bundler'
Bundler.setup()

require 'yaml'
require 'openssl'
require 'rubygems'
require 'optparse'
require 'right_aws'

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
	puts "\"#{options[:config_file]}\" doesn't exist. Please create it."
	exit 1
end
config = YAML::load_file(options[:config_file])

web_ssh_root = "#{config['webserver']['username']}@#{config['webserver']['hostname']}"
# web_ssh_root looks like: username@example.com

db_ssh_root = "#{config['database']['ssh_username']}@#{config['database']['hostname']}"
# db_ssh_root looks like: username@example.com

backup_name = "#{config['site_name']}_backup_#{Time.now.year}-#{Time.now.month}-#{Time.now.day}"
# backup_name looks like: project_name_backup_2011-10-27

tar_command = `which tar`.strip
ssh_command = `which ssh`.strip
nice_command = `which nice`.strip
rsync_command = `which rsync`.strip
mysqldump_command = `which mysqldump`.strip
rm_command = `which rm`.strip

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
	puts "   - #{backup_name}.tgz already exists. Skipping archive generation."

else

	### Make a backup of their code
	print "   - backing up code... "
	code_backup_command = "#{rsync_command} -av \"#{web_ssh_root}:#{config['webserver']['app_root']}/*\" \"#{backup_name}/code/\" > #{backup_name}/backup.log 2>&1"
	unless system(code_backup_command)
		puts "Couldn't download code from #{web_ssh_root}:#{config['webserver']['app_root']} to #{backup_name}/code/. Details in #{backup_name}/backup.log."
		exit 1
	end
	puts "done."

	if File.directory?("#{backup_name}/assets/")
		### Make a backup of their uploaded assets
		print "   - backing up uploaded assets... " 
		asset_backup_command = "#{rsync_command} -av \"#{backup_name}/assets/\" > #{backup_name}/backup.log 2>&1"
		unless system(asset_backup_command)
			puts "Couldn't download assets from #{web_ssh_root}:#{config['webserver']['media_path']} to #{backup_name}/assets/. Details in #{backup_name}/backup.log."
			exit 1
		end
		puts "done."
	end

	if config['webserver']['use_maintenance_flag']
		### Put up the maintenance notice
		print "   - putting up maintenance notice... "
		maintenance_notice_command = "#{ssh_command} \"#{web_ssh_root}\" \"touch #{config['webserver']['app_root']}/maintenance.flag\" 2>#{backup_name}/backup.log"
		unless system(maintenance_notice_command)
			puts "Couldn't put up a maintenance notice. Details in #{backup_name}/backup.log."
			exit 1
		end
		puts "done."
	end

	### Make a backup of their database
	print "   - backing up database... "
	escaped_password = config['database']['password']
	escaped_password.gsub!('!','\\!')
	escaped_password.gsub!('$','\\\\\\\\\\$')
	database_backup_command = "#{ssh_command} \"#{db_ssh_root}\" \"#{mysqldump_command} -u #{config['database']['db_username']} --password=#{escaped_password} #{config['database']['database']}\" > #{backup_name}/database/#{config['database']['database']}.sql 2>#{backup_name}/backup.log"
	unless system(database_backup_command)
		puts "Couldn't make a backup of the current database. Details in #{backup_name}/backup.log."
		exit 1
	end
	puts "done."

	if config['webserver']['use_maintenance_flag']
		### Remove the maintenance notice
		print "   - removing maintenance notice... "
		remove_maintenance_notice_command = "#{ssh_command} \"#{web_ssh_root}\" \"rm #{config['webserver']['app_root']}/maintenance.flag\" 2>#{backup_name}/backup.log"
		unless system(remove_maintenance_notice_command)
			puts "Couldn't remove maintenance notice. Details in #{backup_name}/backup.log."
			exit 1
		end
		puts "done."
	end

	### Excluding paths
	print "   - excluding paths... "
	paths_to_exclude = if config['webserver']['paths_to_exclude'] && config['webserver']['paths_to_exclude'].instance_of?(Array)
						# Convert configs to safeguarded array of paths
						cleaned_paths = config['webserver']['paths_to_exclude'].compact.map do |path_from_config|
							path_from_config.strip!
							File.open("#{backup_name}/backup.log", 'a') { |f| f.write("Path to exclude: #{path_from_config}") }
							if !path_from_config.empty?
								# prepend with backup path to guard against unintended deletions; remove bad leading characters
								"#{backup_name}/code/#{path_from_config.gsub(/^[\/\.]+/,'')}"
							else
								# explicitly map to nil so this is removed
								nil
							end
						end
						# Clean and convert array to string for execution
						if cleaned_paths && cleaned_paths.instance_of?(Array)
							cleaned_paths.compact.join(' ')
						else
							nil
						end
					end
	if paths_to_exclude && !paths_to_exclude.empty?
		exclude_paths_command = "#{rm_command} -rf #{paths_to_exclude} 2>#{backup_name}/backup.log"
		unless system(exclude_paths_command)
			puts "Couldn't exclude paths. Details in #{backup_name}/backup.log."
			exit 1
		end
	end
	puts "done."


	### Tar those backups together
	print "   - compressing backup... "
	compress_backup_command = "#{nice_command} #{tar_command} zcf #{backup_name}.tgz #{backup_name}/*"
	if system(compress_backup_command)
		if(options[:cleanup])
			unless system("rm -rf #{backup_name}")
		 		puts "Couldn't remove pre-archival data. Exiting."
		 		exit 1
			end
		end
	else
		puts "Couldn't compress the backup in #{backup_name}. Exiting."
		exit 1
	end
	puts "done."

end
# Get a list of the generated files
backup_file_list = Dir.glob("#{backup_name}\.tgz*")

### Upload the backup file to Amazon S3
print "   - uploading to amazon cloud... "

s3 = RightAws::S3Interface.new(
	config['amazon']['access_key_id'],
	config['amazon']['secret_access_key'],
	{
		:server     => config['amazon']['server'],
		:port 		=> config['amazon']['port'],
		:protocol 	=> config['amazon']['protocol']
	}
)

begin
	# test for presence of the bucket
	s3.bucket_location(config['amazon']['bucket'])
rescue RightAws::AwsError => e
	if e.message == 'AccessDenied: Access Denied'
		puts "WARNING: access denied when checking bucket. Attempting to continue..."
	else
		# assume permissions to create the bucket
		RightAws::S3::Bucket.create(s3, config['amazon']['bucket'], true, access_control)
	end
end

current_file = nil
begin
	# Check each file to see if it's uploaded
	backup_file_list.each do |file|
		current_file = file
		s3.head(config['amazon']['bucket'], current_file)
		current_file = nil
	end
	### If this succeeds, the backup already exists.

	puts "There is already a backup called #{backup_name} in the bucket #{config['amazon']['bucket']}. Exiting."
	exit 1

rescue RightAws::AwsError => e
	okay_exception = if e.message.include?('404: Not Found')
						# file not uploaded
						true
					elsif e.message.include?('403: Forbidden')
						# assuming file exists but permission denied to read it
						puts "There is already a backup called #{backup_name} in the bucket #{config['amazon']['bucket']}. Exiting."
						exit 1
					else
						false
					end
	if !okay_exception
		# not an expected exception
		puts "Exception: #{e.inspect}"
		raise e
	end

	files_to_upload = backup_file_list.clone
	access_control = config['amazon']['access_control'] ? config['amazon']['access_control'] : 'authenticated-read'

	# prune files_to_upload for each existing file
	if current_file # if this is not nil, an exception prevented it, indicating the file does not exist. This is the first file to upload.
		current_file_index = files_to_upload.index(current_file)

		files_to_upload = files_to_upload[current_file_index...(files_to_upload.length)]
	else
		# if current_file is nil, all backup files already exist. Exit and do nothing.
		puts "Backup files already uploaded. Exiting."
		exit 0
	end

	begin
		files_to_upload.each do |file|
			s3.put(
				config['amazon']['bucket'],
				file,
				File.open(file),
				:content_type => 'application/x-compressed',
				'x-amz-grant-read-acp' => true
			)
		end
	rescue Exception => e
		puts "Exception: #{e.inspect}"
		raise e
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

rescue Exception => e
	puts "Exception: #{e.inspect}"
	raise e
	exit 1
end

puts "done."
