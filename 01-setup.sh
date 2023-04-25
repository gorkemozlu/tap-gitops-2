#!/bin/bash


export AIRGAPPED=$(yq eval '.airgapped' gorkem/values.yaml)
if [ "$AIRGAPPED" = "true" ]; then
    export IMGPKG_REGISTRY_HOSTNAME_0=registry.tanzu.vmware.com
    export IMGPKG_REGISTRY_USERNAME_0=$(yq eval '.tanzuNet_username' ./gorkem/values.yaml)
    export IMGPKG_REGISTRY_PASSWORD_0=$(yq eval '.tanzuNet_password' ./gorkem/values.yaml)
    export IMGPKG_REGISTRY_HOSTNAME_1=$(yq eval '.image_registry' ./gorkem/values.yaml)
    export IMGPKG_REGISTRY_USERNAME_1=$(yq eval '.image_registry_user' ./gorkem/values.yaml)
    export IMGPKG_REGISTRY_PASSWORD_1=$(yq eval '.image_registry_password' ./gorkem/values.yaml)
    export TAP_VERSION=$(yq eval '.tap_version' ./gorkem/values.yaml)
    export TBS_VERSION=$(yq eval '.tbs_version' ./gorkem/values.yaml)
    yq eval '.ca_cert_data' ./gorkem/values.yaml | sed 's/^[ ]*//' > ./gorkem/ca.crt
    export REGISTRY_CA_PATH="$(pwd)/gorkem/ca.crt"

    #imgpkg copy \
    #  -b registry.tanzu.vmware.com/tanzu-application-platform/tap-packages:$TAP_VERSION \
    #  --to-tar tap-packages-$TAP_VERSION.tar \
    #  --include-non-distributable-layers \
    #  --concurrency 30 

    #imgpkg copy \
    #  --tar tap-packages-$TAP_VERSION.tar \
    #  --to-repo $IMGPKG_REGISTRY_HOSTNAME_1/tap-packages/tap \
    #  --include-non-distributable-layers \
    #  --concurrency 30 \
    #  --registry-ca-cert-path $REGISTRY_CA_PATH --debug


#    imgpkg copy -b registry.tanzu.vmware.com/tanzu-application-platform/full-tbs-deps-package-repo:$TBS_VERSION \
#      --to-tar=tbs-full-deps.tar --concurrency 30

#    imgpkg copy --tar tbs-full-deps.tar \
#      --to-repo=$IMGPKG_REGISTRY_HOSTNAME_1/tap-packages/tbs-full-deps --concurrency 30

    yq eval -i ".tap_install.values.buildservice.exclude_dependencies = true" ./gorkem/templates/tap-non-sensitive-values-template.yaml

    export TAP_PKGR_REPO=$IMGPKG_REGISTRY_HOSTNAME_1/tap-packages

    export KAPP_NS=$(kubectl get pods --all-namespaces -l app=kapp-controller -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.status.phase}{"\n"}{end}'|awk '{print $1}')

    #kubectl create secret generic kapp-controller-config \
    #   --namespace $KAPP_NS \
    #   --from-file caCerts=gorkem/ca.crt


    if [ -n "$KAPP_NS" ]; then
        echo "kapp is running"
    else
        echo "kapp is not running, therefore installing."

        imgpkg copy \
          -b registry.tanzu.vmware.com/tanzu-cluster-essentials/cluster-essentials-bundle@sha256:79abddbc3b49b44fc368fede0dab93c266ff7c1fe305e2d555ed52d00361b446 \
          --to-tar cluster-essentials-bundle-1.5.0.tar \
          --include-non-distributable-layers
        imgpkg copy \
          --tar cluster-essentials-bundle-1.5.0.tar \
          --to-repo $IMGPKG_REGISTRY_HOSTNAME_1/tap-packages/cluster-essentials-bundle \
          --include-non-distributable-layers \
          --registry-ca-cert-path $REGISTRY_CA_PATH

        export INSTALL_BUNDLE=$IMGPKG_REGISTRY_HOSTNAME_1/tap-packages/tanzu-cluster-essentials/cluster-essentials-bundle@sha256:79abddbc3b49b44fc368fede0dab93c266ff7c1fe305e2d555ed52d00361b446
        export INSTALL_REGISTRY_HOSTNAME=registry.tanzu.vmware.com
        export INSTALL_REGISTRY_USERNAME=$(yq '.tanzuNet_username' gorkem/values.yaml)
        export INSTALL_REGISTRY_PASSWORD=$(yq '.tanzuNet_password' gorkem/values.yaml)

        cd gorkem/tanzu-cluster-essentials
        ./install.sh --yes
        cd ../..
    fi

fi
echo $AIRGAPPED


export KAPP_NS=$(kubectl get pods --all-namespaces -l app=kapp-controller -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.status.phase}{"\n"}{end}'|awk '{print $1}')
export KAPP_POD=$(kubectl get pods --all-namespaces -l app=kapp-controller -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'|awk '{print $1}')

if [ -n "$KAPP_NS" ]; then
    echo "kapp is running"
else
    echo "kapp is not running, therefore installing."
    export INSTALL_BUNDLE=registry.tanzu.vmware.com/tanzu-cluster-essentials/cluster-essentials-bundle@sha256:79abddbc3b49b44fc368fede0dab93c266ff7c1fe305e2d555ed52d00361b446
    export INSTALL_REGISTRY_HOSTNAME=registry.tanzu.vmware.com
    export INSTALL_REGISTRY_USERNAME=$(yq '.tanzuNet_username' gorkem/values.yaml)
    export INSTALL_REGISTRY_PASSWORD=$(yq '.tanzuNet_password' gorkem/values.yaml)
    
    cd gorkem/tanzu-cluster-essentials
    ./install.sh --yes
    cd ../..
fi



#sleep 10000
# setup sops key

sops_age_file="./gorkem/tmp-enc/key.txt"

if [ -e "$sops_age_file" ]; then
  echo "The file '$sops_age_file' exists. Continuing"
else
  echo "The file '$sops_age_file' does not exist."
  mkdir -p ./gorkem/tmp-enc
  chmod 700 ./gorkem/tmp-enc
  age-keygen -o ./gorkem/tmp-enc/key.txt
fi

export SOPS_AGE_RECIPIENTS=$(cat ./gorkem/tmp-enc/key.txt | grep "# public key: " | sed 's/# public key: //')
export HARBOR_USERNAME=$(yq eval '.image_registry_user' ./gorkem/values.yaml)
export HARBOR_PASSWORD=$(yq eval '.image_registry_password' ./gorkem/values.yaml)
export HARBOR_URL=$(yq eval '.image_registry' ./gorkem/values.yaml)

cat > ./gorkem/tmp-enc/tap-sensitive-values.yaml <<-EOF
---
tap_install:
  sensitive_values:
    shared:
      image_registry:
        username: $HARBOR_USERNAME
        password: $HARBOR_PASSWORD
    buildservice:
      kp_default_repository_password: $HARBOR_PASSWORD
EOF

sops --encrypt ./gorkem/tmp-enc/tap-sensitive-values.yaml > ./gorkem/tmp-enc/tap-sensitive-values.sops.yaml
mv ./gorkem/tmp-enc/tap-sensitive-values.sops.yaml ./clusters/full-profile/cluster-config/values


ytt --ignore-unknown-comments -f ./gorkem/values.yaml -f ./gorkem/templates/tap-non-sensitive-values-template.yaml > ./clusters/full-profile/cluster-config/values/tap-values.yaml

export INSTALL_REGISTRY_HOSTNAME=registry.tanzu.vmware.com
export INSTALL_REGISTRY_USERNAME=$(yq eval '.tanzuNet_username' ./gorkem/values.yaml)
export INSTALL_REGISTRY_PASSWORD=$(yq eval '.tanzuNet_password' ./gorkem/values.yaml)
export GIT_SSH_PRIVATE_KEY=$(cat $HOME/.ssh/id_rsa)
export GIT_KNOWN_HOSTS=$(ssh-keyscan github.com)
export SOPS_AGE_KEY=$(cat ./gorkem/tmp-enc/key.txt)

#sleep 1000
git init && git add . && git commit -m "Big Bang" && git branch -M main
git remote add origin https://github.com/gorkemozlu/tap-gitops-2.git
git push -u origin main

cd ./clusters/full-profile
./tanzu-sync/scripts/configure.sh

git add ./cluster-config/ ./tanzu-sync/
git commit -m "Configure install of TAP 1.5.0"
git push

kubectl create ns my-apps
kubectl label ns my-apps apps.tanzu.vmware.com/tap-ns=""
tanzu secret registry add registry-credentials --username $HARBOR_USERNAME --password $HARBOR_PASSWORD --server $HARBOR_URL --namespace my-apps --export-to-all-namespaces

#./tanzu-sync/scripts/deploy.sh

# additional tools
# kubectl apply -f- gorkem/tools/local-issuer.yaml
# ytt --ignore-unknown-comments -f ./gorkem/values.yaml -f gorkem/tools/gitea.yaml|kubectl apply -f-
# ytt --ignore-unknown-comments -f ./gorkem/values.yaml -f gorkem/tools/nexus.yaml|kubectl apply -f-
# ytt --ignore-unknown-comments -f ./gorkem/values.yaml -f gorkem/tools/minio.yaml|kubectl apply -f-
