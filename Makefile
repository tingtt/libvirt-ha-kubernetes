init:
	terraform init

PORT	?=	8081
apply:
	@if which bunx > /dev/null ; then \
		bunx light-server -s ./kubernetes -p ${PORT} & \
	else \
		if ! which npx > /dev/null ; then \
			echo "Error: node not installed" ; false ; \
		fi ; \
		npx light-server -s ./kubernetes -p ${PORT} & \
	fi
	terraform apply -auto-approve
	sh -c 'sleep 600 && lsof -i:${PORT} -t |xargs kill -9' &

plan:
	terraform plan

destroy:
	terraform destroy
