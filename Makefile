INV := inventory/my_lab
# vagrant flags
NUM_HOSTS := 3
HOST_MEMORY := 32000
HOST_NUM_CPU := 4
HOST_OS := ubuntu2204
HOST_DISK_SIZE := 100
HOST_IP_SUBNET := 192.168.56

# Kubeconfig path after cluster creation
KUBECONFIG := ./kubespray/${INV}/artifacts/admin.conf

.PHONY: clone-kubespray setup-venv install-requirements vagrant-up provision-cluster create-vagrant-cfg longhorn install-longhorn destroy-cluster

# Clone the Kubespray repository
clone-kubespray:
	if [ ! -d "kubespray" ]; then \
		git clone https://github.com/kubernetes-sigs/kubespray.git && cd kubespray && git checkout v2.23.0; \
	fi

vagrant-cluster-config:
	if [ ! -d "kubespray/${INV}" ]; then 
		cp -a ./kubespray/inventory/sample/ kubespray/${INV}
		rm -f kubespray/${INV}/inventory.ini
		echo "dashboard_enabled: true" >> kubespray/${INV}/group_vars/k8s_cluster/addons.yml
		sed -i 's/helm_enabled: false/helm_enabled: true/' kubespray/${INV}/group_vars/k8s_cluster/addons.yml
		sed -i 's/metrics_server_enabled: false/metrics_server_enabled: true/' kuebspray/${INV}/group_vars/k8s_cluster/addons.yml
		echo "kube_token_auth: true" >> kubespray/${INV}/group_vars/k8s_cluster/k8s-cluster.yml
		echo "tls_min_version: \"VersionTLS12\"" >> kubespray/${INV}/group_vars/k8s_cluster/k8s-cluster.yml
		echo "tls_cipher_suites:" >> kubespray/${INV}/group_vars/k8s_cluster/k8s-cluster.yml
		echo "  - TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256" >> kubespray/${INV}/group_vars/k8s_cluster/k8s-cluster.yml
		echo "  - TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384" >> kubespray/${INV}/group_vars/k8s_cluster/k8s-cluster.yml
		echo "  - TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305" >> kubespray/${INV}/group_vars/k8s_cluster/k8s-cluster.yml
		echo "  - TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256" >> kubespray/${INV}/group_vars/k8s_cluster/k8s-cluster.yml
		echo "  - TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384" >> kubespray/${INV}/group_vars/k8s_cluster/k8s-cluster.yml
		echo "  - TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305" >> kubespray/${INV}/group_vars/k8s_cluster/k8s-cluster.yml
	else
		echo "skipping inventory directory"
	fi
	echo "done configuring inventory directory"
	if [ ! -d "./kubespray/venv" ]; then 
		python3 -m venv ./kubespray/venv; 
		. ./kubespray/venv/bin/activate && pip install -r ./kubespray/requirements.txt ; \
	else
		echo "skipping venv directory"
	fi
	echo "done creating virtual env" 
	if [ ! -d "./kubespray/vagrant" ]; then 
		mkdir -p ./kubespray/vagrant
		echo '$$num_instances = ${NUM_HOSTS}' > ./kubespray/vagrant/config.rb
		echo '$$instance_name_prefix = "k8s"' >> ./kubespray/config.rb
		echo '$$vm_memory = ${HOST_MEMORY}' >> ./kubespray/vagrant/config.rb
		echo '$$vm_cpus = ${HOST_NUM_CPU}' >> ./kubespray/vagrant/config.rb
		echo '$$os = "${HOST_OS}"' >> ./kubespray/vagrant/config.rb
		echo '$$kube_node_instances_with_disks = true' >> ./kubespray/vagrant/config.rb
		echo '$$kube_node_instances_with_disks_size = "${HOST_DISK_SIZE}"' >> ./kubespray/vagrant/config.rb 
		echo '$$kube_node_instances_with_disks_number = ${NUM_HOSTS}' >> ./kubespray/vagrant/config.rb
		echo '$$override_disk_size = false' >> ./kubespray/vagrant/config.rb
		echo '$$disk_size = "${HOST_DISK_SIZE}"' >> ./kubespray/vagrant/config.rb
		echo '$$subnet = "${HOST_IP_SUBNET}"' >> ./kubespray/vagrant/config.rb
		echo '$$inventory = "${INV}"' >> ./kubespray/vagrant/config.rb
	else
		echo "skipping ./kubespray/vagrant directory config"
	fi

# Start Vagrant VMs
vagrant-up: 
	cd ./kubespray && vagrant up
	echo "done creating hosts"

# Provision Kubernetes cluster
provision-cluster: 
	cd ./kubespray && \
	. ./venv/bin/activate && \
	ansible-playbook -i ./inventory/my_lab/vagrant_ansible_inventory  --become  --become-method=sudo cluster.yml


fix-multipath:
	. ./kubespray/venv/bin/activate && \
	ansible-playbook -i ./kubespray/${INV}/vagrant_ansible_inventory longhorn/install-longhorn.yml --become --become-method=sudo 

longhorn:
	echo "Starting longhorn install"
	export KUBECONFIG=$(KUBECONFIG); \
	if ! helm list -n longhorn-system | grep -q longhorn; then \
		kubectl create ns longhorn-system; \
		helm repo add longhorn https://charts.longhorn.io; \
		helm repo update; \
		helm install longhorn longhorn/longhorn -f longhorn/longhorn.yml -n longhorn-system; \
	fi
	kubectl apply -f longhorn/storageclass.yaml
	echo "done installing longhorn"

install-longhorn: fix-multipath longhorn

install-prometheus:
	echo "Starting prometheus install"
	export KUBECONFIG=$(KUBECONFIG); \
	if ! helm list -n kube-system | grep -q prometheus; then   \
		helm repo add prometheus-community https://prometheus-community.github.io/helm-charts ; \
		helm repo update ; \
		helm install prom-stack prometheus-community/prometheus -n kube-system ; \
		helm install prom-adapter prometheus-community/prometheus-adapter -n kube-system --set prometheus.url=http://prom-stack-prometheus-server.kube-system.svc:80; \
	fi
	
install-keda:
	echo "Starting keda install"
	export KUBECONFIG=$(KUBECONFIG); \
	if ! helm list -n keda | grep -q keda; then   \
		helm repo add kedacore https://kedacore.github.io/charts; \
		helm repo update ; \
		helm install keda kedacore/keda --namespace keda --create-namespace ; \
	fi

install-autoscaler: install-prometheus install-keda

requirements:
	sudo apt-get install -y python3-pip python3-venv vagrant virtualbox virtualbox-dkms virtualbox-ext-pack 
	sudo snap install kubectl --classic
	sudo snap install helm --classic
	sudo vagrant plugin install landrush --plugin-version 1.3.2
	sudo vagrant plugin install vagrant-libvirt --plugin-version 0.7.0
	sudo vagrant plugin install vagrant-vbguest --plugin-version 0.31.0
	sudo vagrant plugin install vagrant-vboxmanage --plugin-version 0.0.2
	
setup-cluster: clone-kubespary vagrant-up provision-cluster install-longhorn install-autoscaler

destroy-cluster:
	cd ./kubespray && vagrant destroy -f 
	rm -rf kubespray