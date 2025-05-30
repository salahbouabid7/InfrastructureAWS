
#!/bin/bash
retrieve_ip(){
    aws ec2 describe-instances                              \
    --filters "Name=tag:Name,Values=ASG-instance"           \
              "Name=instance-state-name,Values=running"     \
    --query "Reservations[0].Instances[0].PrivateIpAddress" \
    --output text 
}
echo "[*] Sleeping 120s to allow ASG to launch..."
sleep 120

while true;do
ip=$(retrieve_ip)

    if [ -z "${ip}" ];then 
    echo "Instance not launched yet"
    sleep 30
    ip=$(retrieve_ip)

    else
    echo "[+] Private IP found: $ip"
    break;
    fi

done

echo "Private IP found: $ip"
sed -i "s/TOBEREMPLACED/${ip}/g" ./instance-asg

