FROM instructure/rvm

WORKDIR /app

USER root
RUN chown -R docker:docker /app
USER docker

RUN /bin/bash -lc "rvm 2.6,2.7,3.0 do gem install bundler -v 2.2.23"

COPY --chown=docker:docker switchman.gemspec Gemfile Gemfile.lock /app/
COPY --chown=docker:docker lib/switchman/version.rb /app/lib/switchman/version.rb

RUN echo "gem: --no-document" >> ~/.gemrc
RUN mkdir -p .bundle coverage log \
             gemfiles/.bundle \
             spec/dummy/log \
             spec/dummy/tmp

RUN /bin/bash -lc "cd /app && rvm-exec 2.7 bundle install --jobs 5"
COPY --chown=docker:docker . /app
