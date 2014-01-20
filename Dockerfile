# Aukro bot machine
#
# VERSION               0.0.1
#
FROM      filemon/centos_ruby
MAINTAINER Jiri filemon Fabian "jiri.fabian@gmail.com"


# Pull project
RUN git clone https://github.com/filemon/aukro_bot /home/aukro_bot

ADD auctions.yml /home/aukro_bot/
ADD aukro.yml /home/aukro_bot/

# Setup project environment
RUN bundle install --gemfile=/home/aukro_bot/Gemfile --path=vendor

# Open port 4567
# EXPOSE 4567

ENV BUNDLE_GEMFILE /home/aukro_bot/Gemfile

WORKDIR /home/aukro_bot

ENTRYPOINT ["ruby", "bidder.rb"]
