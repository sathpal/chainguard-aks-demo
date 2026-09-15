.PHONY: tools build scan sbom verify report run stop aks-up acr-push deploy policy aks-down clean demo
tools:     ; ./scripts/install-tools.sh
build:     ; ./scripts/build.sh
scan:      ; ./scripts/scan.sh
sbom:      ; ./scripts/sbom.sh
verify:    ; ./scripts/verify.sh
report:    ; ./scripts/report.py && open out/report.html
run:       ## run both images locally on :8081 (upstream) and :8082 (chainguard)
	docker run -d --rm --name demo-upstream   -p 8081:8080 demo-app:upstream
	docker run -d --rm --name demo-chainguard -p 8082:8080 demo-app:chainguard
	@echo "upstream   -> http://localhost:8081"; echo "chainguard -> http://localhost:8082"
stop:      ; -docker rm -f demo-upstream demo-chainguard
aks-up:    ; ./scripts/aks-up.sh
acr-push:  ; ./scripts/acr-push.sh
deploy:    ; ./scripts/deploy.sh
policy:    ; ./scripts/policy.sh
aks-down:  ; ./scripts/aks-down.sh
clean:     ; rm -rf out/*; -docker rmi demo-app:upstream demo-app:chainguard
demo: build scan verify sbom report   ## full local demo, no Azure needed
