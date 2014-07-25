require 'digest'
require 'zip'
require 'flickraw'
require 'open-uri'
require 'gibberish'
require 'shellwords'

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
		@MAX_SIZE = 200 - (File.size(gif_path).to_f / 2**20)

		@filesizes = {}
		setup_flickr
	end

	def setup_flickr
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
			puts "Navigate to this url to authorize your account: "
			puts auth_url
			puts "enter confirmation #: "
			verify = gets.strip
		 	flickr.get_access_token(token['oauth_token'], token['oauth_token_secret'], verify)
		end
	end

	# build hash of filenames mapped to their size in megabytes
	def build_filesizes
		Dir.foreach(@source_path) do |file|
			next if file == '.' || file == '..' || file == '.DS_Store'
			filesize = File.size("#{@source_path}/#{file}").to_f / 2**20
			next if filesize > @MAX_SIZE 
			@filesizes[file] = filesize
		end
	end
	
	# returns array of available files whose cumulative sizes are under the max_upload_size
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
	def create_archive(files)
		puts "Enter your encryption key: "
		key = gets.chomp
		cipher = Gibberish::AES.new(key)
		File.delete(@destination_path+ARCHIVE_FILE) if File.exists?(@destination_path+'/'+ARCHIVE_FILE)
		Zip::File.open(@destination_path+ARCHIVE_FILE, Zip::File::CREATE) do |zipfile|
			Dir.glob(@source_path+'**/*').each do |file|
				next if File.directory?(file)
				cipher.encrypt_file(file, file+'.enc')
				zipfile.add(file.sub(@source_path,'')+'.enc',file+'.enc')
			end
		end
	end

	# concatenates the archive file and gif to form the combined gif
	# return name of combined file
	def build_backup
		combined_file = Time.now.to_i.to_s
		system("cat #{@gif_path} #{@destination_path}/#{ARCHIVE_FILE} > #{@destination_path}/#{combined_file}.gif")
		combined_file
	end
	
	# takes the combined image and uploads it to flickr
	# returns the id of the uploaded image
	def do_upload(combined_image, title='stuffr-backup', tags)
		begin
			return flickr.upload_photo(combined_image, :title => title, :tags => tags, :is_public => 0)
		rescue FlickRaw::FailedResponse => e
		  puts "Authentication failed : #{e.msg}"
		end
	end

	def run_backup
		build_filesizes
		files_to_backup = accumulate_files
		ids = []
		until files_to_backup.empty? do
			create_archive(files_to_backup)
			combined_file = build_backup
			hashed_filenames = files_to_backup.map{|file| Digest::SHA1.hexdigest(file)}
			archive_id = do_upload(@destination_path+'/'+combined_file+'.gif',combined_file, hashed_filenames.join(" ") )
			system("rm -rf #{@destination_path}/#{combined_file}.gif")
			log_archive(archive_id, hashed_filenames, files_to_backup)
			ids << archive_id
			files_to_backup = accumulate_files
		end
		system("rm -rf #{@destination_path}/#{ARCHIVE_FILE}")
		puts "uploads complete"
		puts ids
	end

	def log_archive(archive_id, hashed_filenames, raw_filenames)
		File.open('hoardr-archive.txt', 'a') do |archive_log|
			hashed_filenames.each_with_index do |f, i|
				archive_log.write( Marshal.dump(ArchivedFile.new(raw_filenames[i],f, archive_id)))
				archive_log.write("\n")
			end
		end
	end
	
	def read_archives
		return unless File.exists?('hoardr-archive.txt')
		File.open('hoardr-archive.txt', 'r').each do |line|
			archived_file = Marshal.load(line)
			puts archived_file.inspect
		end
	end

	def archived_files
		return unless File.exists?('hoardr-archive.txt')
		File.open('hoardr-archive.txt', 'r').each do |line|
			archived_file = Marshal.load(line)
			puts archived_file.filename
		end
	end

	# retrieves an entire archive folder 
	def download_raw_archive(archive_id)
		info = flickr.photos.getInfo(:photo_id => archive_id)
		photo_url = FlickRaw.url_o(info)
		open("#{archive_id}.gif", 'wb') do |file|
			file << open(photo_url).read
		end
		system("mv #{archive_id}.gif #{archive_id}.zip | unzip #{archive_id}.zip -d #{@destination_path}#{archive_id}")
		system("rm -rf #{archive_id}.zip")
	end
	
	def retrieve_archive(archive_id)
		download_raw_archive(archive_id)
		puts "Enter your decryption key: "
		key = gets.chomp
		cipher = Gibberish::AES.new(key)
		Dir.glob("#{@destination_path}#{archive_id}/**/*").each do |file|
			next if File.directory?(file)
			cipher.decrypt_file(file, file.sub('.enc', ''))
			system("rm %s" % Shellwords.escape(file))
		end
	end
	
	# retrieves a single archived file
	def download_raw_file(filename)
		return unless file_is_archived?(filename)
		archive_id = get_file_archive_id(filename)
		download_archive(archive_id)
		if( File.directory?(@destination_path+"downloaded_files/"))
			system("cp #{archive_id}/#{filename} ../downloaded_files")
		else
			system("mkdir #{destination_path}downloaded_files | cp #{archive_id}/#{filename} #{@destination_path}downloaded_files")
		end
	end

	def retrieve_archived_file(filename)
		download_raw_file(filename)
		puts "Enter your decryption key: "
		key = gets.chomp
		cipher = Gibberish::AES.new(key)
		cipher.decrypt_file("#{@destination_path}downloaded_files/#{filename}.enc", filename)	
		system("rm -rf #{archive_id}")
		system("rm %s" % Shellwords.escape("#{filename}.enc"))
	end
	
	def find_file_on_flickr(filename)
		flickr.photos.search(:tags => Digest::SHA1.hexdigest(filename), :user_id => "me")
	end

	def all_hashed_filenames
		flickr.tags.getListUser["tags"].inspect
	end
	
	def file_is_archived?(filename)
		open('hoardr-archive.txt'){ |f| return f.grep(/#{filename}/).size > 0 }
	end
	
	def get_file_archive_id(filename)
		return unless file_is_archived?(filename)
		file = nil
		open('hoardr-archive.txt'){ |f|  file = Marshal.load(f.grep(/#{filename}/)[0]) }
		file.archive_id
	end
end

class ArchivedFile
	attr_accessor :filename, :hashed_filename, :archive_id
	def initialize(filename, hashed_filename, archive_id )
		@filename = filename
		@hashed_filename = hashed_filename
		@archive_id = archive_id
	end
end