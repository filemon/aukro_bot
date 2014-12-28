#role :host, "XXX.XXX.XXX.XXX" or set via HOSTS variable
set :user, "root"
set :use_sudo, false
set :ssh_options, {forward_agent: true}


task :clean do
  #clean stopped containers
  run "docker rm $(docker ps -a -q)"
  #clean untagged images
  run "docker rmi $(docker images| grep \"^<none>\" | awk '{print $3}')"
end


task :install do
  run "mkdir -p aukro_bot"
  upload "auctions.yml", "aukro_bot/auctions.yml", :via => :scp
  upload "aukro.yml", "aukro_bot/aukro.yml", :via => :scp
  upload "Dockerfile", "aukro_bot/Dockerfile", :via => :scp
  run 'cd aukro_bot && docker build --rm --no-cache -t="aukro_bot" .'
end

task :start do
  run "docker run -d aukro_bot"
end

task :stop do
  run "docker stop $(docker ps|grep aukro_bot:latest|awk '{print $1}')"
end

task :status do
  run "docker logs -f $(docker ps|grep aukro_bot:latest|awk '{print $1}')"
end