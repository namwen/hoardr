require_relative 'hoardr'

# create an instance of hoardr
hoardr = Hoardr.new('PATH_TO_BACKUP', 'OUTPUT_PATH','PATH_TO_GIF','FLICKR_KEY','FLICKR_SECRET')

# run the backup on the specified directory
hoardr.run_backup

# download a single archived file
hoardr.retrieve_archived_file("example.rb")

# get the archive id of a specific file
archive_id = hoardr.get_file_archive_id("example.rb")

# download entire archive
hoardr.retrieve_archive(archive_id)

