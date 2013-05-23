Magento Backup
==============

This is a COPIOUS script to backup a Magento instance.  It pulls uploaded media and an SQL dump, compresses them, and copies them to an Amazon S3 bucket.

Prerequisites
-------------

This requires ruby and rubygems, first and foremost.  If you don't have those installed already, you'll want to download and install them:

* [Ruby](http://www.ruby-lang.org/en/)
* [RubyGems](https://rubygems.org/pages/download)

Ruby will need the OpenSSL libraries. If you haven’t installed them, do this (Ubuntu):

		$ sudo apt-get install libopenssl-ruby

This also requires the Amazon S3 ruby gem to be present.  Assuming you're using [RVM](http://beginrescueend.com/) and [Bundler](http://gembundler.com/), do this:

		$ gem install bundler
		$ bundle install

If you're not using those tools, have sudo access and do this:

		$ sudo gem install aws-s3

Back it up.
-----------

To use it, drop your authentication vectors into a `magento_backup.yml` file to look like this:

		site_name: your_app_name
		database:
		    ssh_username: your_ssh_username
		    db_username: your_mysql_username
		    password: your_password
		    hostname: your_app.staging.copiousdev.com
		    database: your_app_staging
		amazon:
		    bucket: your_app_backups
		    secret_access_key: your_secret
		    access_key_id: your_key_id
		webserver: 
		    username: your_ssh_username
		    hostname: your_app.staging.copiousdev.com
		    app_root: /var/www/your_app-staging
		    media_path: /var/www/your_app-staging/media
		    paths_to_skip:
		        - var

Once that's in place, run the script:

		$ bundle exec ruby ./magento_backup.rb

It should produce output roughly equivalent to this:

		Creating backup magento_backup_2011-10-27...
		   - backing up uploaded assets... done.
		   - putting up maintenance notice... done.
		   - backing up database... done.
		   - removing maintenance notice... done.
		   - skipping paths... done.
		   - compressing backup... done.
		   - splitting backups... done.
		   - uploading to amazon cloud... done.
		   - removing local copy of the backup... done.
		done.

Restoring
---------

To restore from a backup, you'll first need to pull all of the partitioned backup files back down from Amazon S3 using their web client at http://aws.amazon.com/.  Once you have a local copy of these, you'll need to reassemble them into a tgz file:

		$ cat `ls magento_backup_2012-06-14.tgz.*` ... > magento_backup_2012-06-14.tgz

Then you'll need to extract the archive using tar and gzip:

	  $ tar zxvf magento_backup.tgz

This will create a directory containing the assets, code, and database dump of the backup Magento data.

License
-------

This software is available under the Academic Free License, version 3.0:

http://www.opensource.org/licenses/afl-3.0.php
