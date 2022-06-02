# Switchman Development

A simple docker environment has been provided for spinning up and testing this
gem with multiple versions of Ruby. This requires docker and docker-compose to
be installed. To get started, run the following:

```bash
./build.sh
```

This will install the gem in a docker image with all versions of Ruby installed,
and install all gem dependencies in the Ruby 2.5 set of gems. It will also
download and spin up a PostgreSQL container for use with specs.

The first build will take a long time, however, docker images and gems are
cached, making additional runs significantly faster.

Individual spec runs can be started by resetting the DB, and running RSpec with
your custom options like so:

```bash
docker-compose run --rm app /bin/bash -lc \
  "bundle exec rake db:drop db:create db:migrate"
docker-compose run --rm app /bin/bash -lc \
  "bundle exec rspec spec/lib/rails_spec.rb"
docker-compose run --rm app /bin/bash -lc \
  "bundle exec rspec spec/lib/active_record/query_methods_spec.rb"
```

Note that these will only run against one version of active record^. You can use
the "appraise" keyword to run against specific versions listed in the Appraisals file,
or all of them by using "appraisal" with no argument:

```bash
docker-compose run --rm app /bin/bash -lc \
  "bundle exec appraisal activerecord-6.0 rspec"
docker-compose run --rm app /bin/bash -lc \
  "bundle exec appraisal rspec"
```

Or you can boot a bash terminal one time interactively, and then run what you want inside there:

```bash
docker-compose run --rm app /bin/bash
bundle exec rake db:drop db:create db:migrate
bundle exec appraisal activerecord-6.0 rspec
bundle exec appraisal rspec
```

If you'd like to mount your git checkout within the docker container running
tests so changes are easier to test, use the override provided:

```bash
cp docker-compose.override.example.yml docker-compose.override.yml
```

Also note that you can run specs against specific versions of ActiveRecord by
setting `BUNDLE_GEMFILE`, e.g.:

```bash
docker-compose run --rm app /bin/bash -lc \
  "BUNDLE_GEMFILE=gemfiles/activerecord_5.2.3.gemfile bundle exec rspec"
```

## Code Coverage

Code coverage reports are enabled by default, and when using build.sh, the data
will automatically be copied out of the docker containers running specs, and
into your local "coverage" directory.

## Making a new Release

To install this gem onto your local machine, run `bundle exec rake install`. To
release a new version, update the version number in `version.rb`, and then just
run `bundle exec rake release`, which will create a git tag for the version,
push git commits and tags, and push the `.gem` file to
[rubygems.org](https://rubygems.org).
