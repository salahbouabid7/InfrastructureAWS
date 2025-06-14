#!/bin/bash

retrieve_ip() {
    aws ec2 describe-instances \
        --filters "Name=tag:Name,Values=webapp-asg" \
                  "Name=instance-state-name,Values=running" \
        --query "Reservations[].Instances[].PrivateIpAddress" \
        --output text
}

echo "[*] Sleeping 90s to allow ASG to launch..."
sleep 90

while true; do
    ip=$(retrieve_ip)

    if [[ -z "$ip" || "$ip" == "None" ]]; then
        echo "[-] Instance not launched yet or no IP found."
        sleep 30
    else
        echo "[+] Private IP found: $ip"
        break
    fi
done

echo "Private IP found: $ip"

sed -i "s/TOBEREMPLACED/${ip}/g" ./instance-asg
cat ./instance-asg
