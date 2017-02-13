# -*- mode: ruby -*-
# vi: set ft=ruby :

Vagrant.configure(2) do |config|
  config.vm.provider "virtualbox" do |v|
   v.memory = 8192
   v.cpus = 2
  end

  config.vm.box = "bento/ubuntu-16.04"

  # config.vm.synced_folder ".", "/go/src/github.com/coreos/flannel"

  config.vm.provision "shell", inline: <<-SHELL
    set -e -x -u

    apt-get update -y || (sleep 40 && apt-get update -y)
    apt-get install -y golang git vim docker.io
    echo "export GOPATH=/go" >> /root/.bashrc
    mkdir -p /go/src/github.com/coreos
    cp -a /vagrant /go/src/github.com/coreos/flannel
  SHELL
end
