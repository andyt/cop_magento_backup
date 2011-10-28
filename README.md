Magento Backup
==============

This is a COPIOUS script to backup a Magento instance.  It pulls uploaded media and an SQL dump, compresses them, and copies them to an Amazon S3 bucket.

Prerequisites
-------------

This requires ruby and rubygems, first and foremost.  If you don't have those installed already, you'll want to download and insall them:

* [Ruby](http://www.ruby-lang.org/en/)
* [RubyGems](https://rubygems.org/pages/download)

This also requires the Amazon S3 ruby gem to be present.  Assuming you're using [RVM](http://beginrescueend.com/) and [Bunler](http://gembundler.com/), do this:

		$ gem install bundler
		$ bundle install

If you're not using those tools, have sudo access and do this:

		$ sudo gem install aws-s3

Back it up.
-----------

To use it, drop your authentication vectors into a magento_backup.yml file to look a little something like this:

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

Once that's in place, simply run the script:

		$ ./magento_backup.rb

It should produce output roughly equivalent to this:

		Creating backup sportswave_backup_2011-10-27...
		   - backing up uploaded assets... done.
		   - putting up maintenance notice... done.
		   - backing up database... done.
		   - removing maintenance notice... done.
		   - compressing backup... done.
		   - uploading to amazon cloud... done.
		   - removing local copy of the backup... done.
		done.
