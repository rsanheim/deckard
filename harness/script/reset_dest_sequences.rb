# Restart destination PK sequences well above the source IDs so bin/verify
# can tell remapped destination IDs from accidentally preserved source IDs.
%w[authors profiles posts comments].each do |table|
  ActiveRecord::Base.connection.execute("SELECT setval('#{table}_id_seq', 100000)")
end
