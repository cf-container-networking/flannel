#!/bin/bash


ETCD_IMG="quay.io/coreos/etcd:v3.0.3"
FLANNEL_NET="10.10.0.0/16"
FLANNEL0_SUBNET="10.10.1.1/24"

usage() {
	echo "$0 FLANNEL-DOCKER-IMAGE"
	echo
	echo "Run end-to-end tests by bringing up two flannel instances"
	echo "and having them ping each other"
	echo
	echo "NOTE: this script depends on Docker 1.9.0 or higher"
	exit 1
}

version_check() {
	required=$1
	actual=$2
	err_prefix=$3

	req_maj=$(echo $required | cut -d . -f 1)
	req_min=$(echo $required | cut -d . -f 2)
	act_maj=$(echo $actual | cut -d . -f 1)
	act_min=$(echo $actual | cut -d . -f 2)

	if [ $act_maj -lt $req_maj ] || ( [ $act_maj -eq $req_maj ] && [ $act_min -lt $req_min ] ); then
		echo "$err_prefix: required=$required, found=$actual"
		exit 1
	fi
}

docker_version_check() {
	ver=$(docker version -f '{{.Server.Version}}')
	version_check "1.9" $ver
}

run_test() {
	backend=$1

	flannel_conf="{ \"Network\": \"$FLANNEL_NET\", \"Backend\": { \"Type\": \"${backend}\" } }"

	# etcd might take a bit to come up
	while ! docker run --rm -it --entrypoint=/usr/local/bin/etcdctl $ETCD_IMG \
			--endpoints=$etcd_endpt set /coreos.com/network/config "$flannel_conf"
	do
		sleep 1
	done

	echo flannel config written

	# flannel0 container has existing subnet.env 
	docker rm -f flannel-e2e-test-flannel0 2>/dev/null
	docker run --name=flannel-e2e-test-flannel0 -d --privileged $flannel_img /bin/sh -c "\
            mkdir -p /run/flannel && \
            echo -e \"FLANNEL_NETWORK=$FLANNEL_NET\nFLANNEL_SUBNET=$FLANNEL0_SUBNET\n\" \
            > /run/flannel/subnet.env && \
            cd /opt/bin && \
            /opt/bin/flanneld --etcd-endpoints=$etcd_endpt"
	if [ $? -ne 0 ]; then
		exit 1
	fi

	# flannel1 gets a new lease from etcd
	docker rm -f flannel-e2e-test-flannel1 2>/dev/null
	docker run --name=flannel-e2e-test-flannel1 -d --privileged --entrypoint=/opt/bin/flanneld $flannel_img --etcd-endpoints=$etcd_endpt
	if [ $? -ne 0 ]; then
		exit 1
	fi

	# flannel2 is the source to ping other containers
	docker rm -f flannel-e2e-test-flannel2 2>/dev/null
	docker run --name=flannel-e2e-test-flannel2 -d --privileged --entrypoint=/opt/bin/flanneld $flannel_img --etcd-endpoints=$etcd_endpt
	if [ $? -ne 0 ]; then
		exit 1
	fi

	# flannel3 has the same subnet.env as flannel0 (conflict), so it gets a new lease
	docker rm -f flannel-e2e-test-flannel3 2>/dev/null
	docker run --name=flannel-e2e-test-flannel3 -d --privileged $flannel_img /bin/sh -c "\
            mkdir -p /run/flannel && \
            echo -e \"FLANNEL_NETWORK=$FLANNEL_NET\nFLANNEL_SUBNET=$FLANNEL0_SUBNET\n\" \
            > /run/flannel/subnet.env && \
            cd /opt/bin && \
            /opt/bin/flanneld --etcd-endpoints=$etcd_endpt"
	if [ $? -ne 0 ]; then
		exit 1
	fi

	echo flannels running

	# wait an arbitrary amount to have flannels come up
	sleep 5

        ping_dest0=$(echo $FLANNEL0_SUBNET | cut -f 1 -d "/")
	# add a dummy interface with to flannel0 with $FLANNEL0_SUBNET (subnet from pre-existing subnet.env file)
	docker "exec" --privileged flannel-e2e-test-flannel0 /bin/sh -c '\
		source /run/flannel/subnet.env && 
		ip link add name dummy0 type dummy && \
		ip addr add $FLANNEL_SUBNET dev dummy0 && \
	       	ip link set dummy0 up'
	echo ""
	echo pinging flannel0
	docker exec -it --privileged flannel-e2e-test-flannel2 /bin/ping -c 5 $ping_dest0

        # TODO AND this with exit code above
	exit_code=$?

	# add a dummy interface to flannel1 with $FLANNEL_SUBNET so we have a known working IP to ping
	# discover the address from the subnet.env written after it gets a lease from etcd, so we can ping it
	ping_dest1=$(docker "exec" --privileged flannel-e2e-test-flannel1 /bin/sh -c '\
		source /run/flannel/subnet.env && 
		ip link add name dummy0 type dummy && \
		ip addr add $FLANNEL_SUBNET dev dummy0 && \
	       	ip link set dummy0 up && \
		echo $FLANNEL_SUBNET | cut -f 1 -d "/" ')

	echo ""
	echo pinging flannel1
	docker exec -it --privileged flannel-e2e-test-flannel2 /bin/ping -c 5 $ping_dest1
        # TODO AND this with exit code above
	exit_code=$?

	# add a dummy interface to flannel3 with $FLANNEL_SUBNET
        # subnet.env should be overwritten after it gets a new lease from etcd
	# discover the address from the subnet.env written after it gets a lease from etcd, so we can ping it
	ping_dest3=$(docker "exec" --privileged flannel-e2e-test-flannel3 /bin/sh -c '\
		source /run/flannel/subnet.env && 
		ip link add name dummy0 type dummy && \
		ip addr add $FLANNEL_SUBNET dev dummy0 && \
	       	ip link set dummy0 up && \
		echo $FLANNEL_SUBNET | cut -f 1 -d "/" ')

	echo ""
	echo pinging flannel3
	docker exec -it --privileged flannel-e2e-test-flannel2 /bin/ping -c 5 $ping_dest3
        # TODO AND this with exit code above
	exit_code=$?

	# Uncomment to debug (you can nsenter)
	if [ $exit_code -eq "1" ]; then
		sleep 10000
	fi

	echo "Test for backend=$backend: exit=$exit_code"

	docker stop flannel-e2e-test-flannel0 flannel-e2e-test-flannel1 flannel-e2e-test-flannel2 flannel-e2e-test-flannel3 >/dev/null

#	if [ $exit_code -ne 0 ]; then
		# Print flannel logs to help debug
		echo "------ flannel server (existing subnet.env) log -------"
		docker logs flannel-e2e-test-flannel0
		echo

		echo "------ flannel server (new sublease) log -------"
		docker logs flannel-e2e-test-flannel1
		echo

		echo "------ flannel client (one doing the ping) log -------"
		docker logs flannel-e2e-test-flannel2
		echo

		echo "------ flannel server (new sublease overwrites conflicting subnet.env) log -------"
		docker logs flannel-e2e-test-flannel3
		echo

		echo "------ etcd dump -----------"
		docker exec flannel-e2e-test-etcd /bin/sh -c 'for n in $(etcdctl ls /coreos.com/network/subnets); do echo -n "$n : " && etcdctl get $n; done'
#	fi

	docker rm flannel-e2e-test-flannel0 flannel-e2e-test-flannel1 flannel-e2e-test-flannel2 flannel-e2e-test-flannel3 >/dev/null

	return $exit_code
}

if [ $# -ne 1 ]; then
	usage
fi

flannel_img=$1

# Check that docker is new enough
docker_version_check

docker0=$(ip -o -f inet addr show docker0 | grep -Po 'inet \K[\d.]+')
etcd_endpt="http://$docker0:2379"

docker rm -f flannel-e2e-test-etcd 2>/dev/null
docker run --name=flannel-e2e-test-etcd -d -p 2379:2379 --entrypoint /usr/local/bin/etcd $ETCD_IMG --listen-client-urls http://0.0.0.0:2379 --advertise-client-urls $etcd_endpt
if [ $? -ne 0 ]; then
	exit 1
fi

echo etcd launched

global_exit_code=0

#backends=${BACKEND:-"udp vxlan host-gw"} 
backends=${BACKEND:-"vxlan"} 
for backend in $backends; do
	echo
	echo "=== BACKEND: $backend ==============================================="

	if ! run_test $backend; then
		global_exit_code=1
	fi
done

docker stop flannel-e2e-test-etcd >/dev/null

if [ $global_exit_code -eq 0 ]; then
	echo
	echo "ALL TESTS PASSED"
else
	# Print etcd logs to help debug
	echo "------ etcd log -------"
	docker logs flannel-e2e-test-etcd
	echo
	echo "TEST(S) FAILED"
fi

docker rm flannel-e2e-test-etcd 2>/dev/null

exit $global_exit_code
