require 'zip'
require 'flickraw'

class Hoardr 
	attr_accessor :flickr_api_key
	attr_accessor :flickr_api_secret
	ARCHIVE_FILE = "hoardr_archive.zip"
	
	def initialize(source_path, destination_path, gif_path, flickr_api_key, flickr_api_secret)
		@source_path = source_path
		@destination_path = destination_path
		@gif_path = gif_path

		@flickr_api_key = flickr_api_key 
		@flickr_api_secret = flickr_api_secret

		@MAX_SIZE = 8 - (File.size(gif_path).to_f / 2**20)

		@filesizes = {}
	end


	# build hash of filenames mapped to their size in megabytes
	def build_filesizes
		Dir.foreach(@source_path) do |file|
			next if file == '.' || file == '..'
			filesize = File.size("#{@source_path}/#{file}").to_f / 2**20
			next if filesize > @MAX_SIZE
			@filesizes[file] = filesize
		end
	end
	# returns 200mb block of files
	# array of files whose cumulative sizes are under the max_upload_size
	def accumulate_files
		files = []
		temp_size = 0
		not_done = true
		while temp_size <= @MAX_SIZE && not_done
			@filesizes.each do |key,value| 
				next if temp_size+value > @MAX_SIZE
				temp_size+=value
				files << key 
				@filesizes.delete(key)
			end
			not_done = false
		end
		files
	end

	# pass in files to be archived ( already filtered by size )
	# return success or failure of archive creation
	def create_archive(files)
		File.delete(@destination_path+'/'+ARCHIVE_FILE) if File.exists?(@destination_path+'/'+ARCHIVE_FILE)
		Zip::File.open(@destination_path+'/'+ARCHIVE_FILE, Zip::File::CREATE) do |zipfile|
			files.each do |file|
				zipfile.add(file, @source_path+'/'+file)
			end
		end
	end
	
	# concatenates the archive file and gif to form the combined gif
	# return name of combined file for use later
	def build_backup
		combined_file = Time.now.to_i.to_s
		system("cat #{@gif_path} #{@destination_path}/#{ARCHIVE_FILE} > #{@destination_path}/#{combined_file}.gif")
		combined_file
	end
	
	# takes the combined image and uploads it to flickr
	# returns the id of the uploaded image, to be used for data logging
	def do_upload(combined_image, title='stuffr-backup')
		FlickRaw.api_key = @flickr_api_key
		FlickRaw.shared_secret = @flickr_api_secret
		if File.exists?('flickr-tokens.txt')
			line = nil
			File.open('flickr-tokens.txt', 'r'){ |file| line = file.readline }
			tokens = line.split
			flickr.access_token = tokens[0]
			flickr.access_secret = tokens[1]
		else
			token = flickr.get_request_token
			auth_url = flickr.get_authorize_url(token['oauth_token'], :perms => 'delete')
			puts "navigate to this url to authorize: "
			puts auth_url
			puts "enter confirmation #: "
			verify = gets.strip
		 	flickr.get_access_token(token['oauth_token'], token['oauth_token_secret'], verify)
		end
		begin
			return flickr.upload_photo(combined_image, :title => title, :is_public => 0)
		rescue FlickRaw::FailedResponse => e
		  puts "Authentication failed : #{e.msg}"
		end
	end

	def run_backup
		build_filesizes
		files_to_backup = accumulate_files
		i = 0
		ids = []
		until files_to_backup.empty? do
			puts i
			create_archive(files_to_backup)
			combined_file = build_backup
			ids << do_upload(@destination_path+'/'+combined_file+'.gif',combined_file )
			files_to_backup = accumulate_files
			i+=1
		end
		puts "uploads complete"
		puts ids
	end
end

hoardr = Hoardr.new('SOURCH_PATH', 'DESTINATION_PATH','GIF_PATH','API_KEY','API_SECRET')
hoardr.run_backup