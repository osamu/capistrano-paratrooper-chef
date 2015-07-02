
Capistrano::Configuration.instance.load do
  def chef_attributes(hosts, attr)
    find_servers.select {|s| hosts.include?(s.host) }.each do |server|
      server.options[:chef_attributes] = attr unless attr.nil?
    end
  end
end
