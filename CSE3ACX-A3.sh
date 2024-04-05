#!/bin/bash

# Create log file
runDate=$(date +"%Y%m%d-%H%M")
logFile=~/$0-$runDate
echo "Script Starting @ $runDate" > $logFile

# Create VPC
VPC=$(aws ec2 create-vpc \
    --cidr-block 172.16.0.0/16 \
    --tag-specifications 'ResourceType=vpc,Tags=[{Key=Name,Value=a3VPC},{Key=Project,Value="CSE3ACX-A3"}]'  \
    --query Vpc.VpcId --output text)

# Create public subnet in the new VPC
subnet0=$(aws ec2 create-subnet --vpc-id "$VPC" --cidr-block 172.16.0.0/24 --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=Subnet0 Public}]' --availability-zone us-east-1a --query Subnet.SubnetId --output text)

# Determine the route table id for the VPC
PubRouteTable=$(aws ec2 describe-route-tables --query "RouteTables[?VpcId == '$VPC'].RouteTableId" --output text)

# Update tag
aws ec2 create-tags --resources $PubRouteTable --tags 'Key=Name,Value=Public route Table'

# Create Internet Gateway
internetGateway=$(aws ec2 create-internet-gateway --query InternetGateway.InternetGatewayId --output text)

# Attach gateway to VPC
aws ec2 attach-internet-gateway --vpc-id "$VPC" --internet-gateway-id "$internetGateway"

# Create default route to Internet Gateway
aws ec2 create-route --route-table-id "$PubRouteTable" --destination-cidr-block 0.0.0.0/0 --gateway-id "$internetGateway" --query 'Return' --output text

# Apply Public route table to subnet0
aws ec2 associate-route-table --subnet-id "$subnet0" --route-table-id "$PubRouteTable" --query 'AssociationState.State' --output text

# Obtain public IP address on launch
aws ec2 modify-subnet-attribute --subnet-id "$subnet0" --map-public-ip-on-launch

# Create private subnet in the VPC
subnet1=$(aws ec2 create-subnet --vpc-id "$VPC" --cidr-block 172.16.1.0/24 --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=Subnet1 Private}]' --availability-zone us-east-1a --query Subnet.SubnetId --output text)

# Create private route table
PrivRouteTable=$(aws ec2 create-route-table --vpc-id "$VPC" --tag-specifications 'ResourceType=route-table,Tags=[{Key=Name,Value=Private Route Table}]' --query RouteTable.RouteTableId --output text)

# Apply Private route table to subnet1
aws ec2 associate-route-table --subnet-id "$subnet1" --route-table-id "$PrivRouteTable" --query 'AssociationState.State' --output text


# Create.ssh folder if it doesn't exist
if [ ! -d ~/.ssh/ ]; then
  mkdir ~/.ssh/
  echo "Creating directory"
fi

# Generate Key Pair
aws ec2 create-key-pair --key-name CSE3ACX-A3-key-pair --query 'KeyMaterial' --output text > ~/.ssh/CSE3ACX-A3-key-pair.pem

# Change permissions of Key Pair
chmod 400 ~/.ssh/CSE3ACX-A3-key-pair.pem

# Create Security Group for public host
publicSG=$(aws ec2 create-security-group --group-name publicSG --description "Security group for host in public subnet" --vpc-id "$VPC" --query 'GroupId' --output text)

# Allow SSH 
aws ec2 authorize-security-group-ingress --group-id "$publicSG" --protocol tcp --port 22 --cidr 0.0.0.0/0 --query 'Return' --output text

# Create Security Group for private host
privateHostSG=$(aws ec2 create-security-group --group-name privateHost-sg --description "Security group for host in private subnet" --vpc-id "$VPC" --query 'GroupId' --output text)

# Allow SSH from private host
aws ec2 authorize-security-group-ingress --group-id "$privateHostSG" --protocol tcp --port 22 --source-group "$publicSG"  --query 'Return' --output text

# Create public EC2 Instance
pubEC2ID=$(aws ec2 run-instances --image-id ami-0b0dcb5067f052a63 --count 1 --instance-type t2.micro --key-name CSE3ACX-A3-key-pair --security-group-ids "$publicSG" --subnet-id "$subnet0" --user-data file://CSE3ACX-A3-public-user-data.txt --query Instances[].InstanceId --output text)

# Determine public IP address of instance
pubIP=$(aws ec2 describe-instances --instance-ids $pubEC2ID --query Reservations[].Instances[].PublicIpAddress --output text)

# Allocate an Elastic IP address
natPubIP=$(aws ec2 allocate-address --query 'PublicIp' --output text)

# Determine allocation IP
eipalloc=$( aws ec2 describe-addresses --query "Addresses[?PublicIp == '$natPubIP'].AllocationId" --output text )

# Create NAT gateway
natID=$(aws ec2 create-nat-gateway --subnet-id $subnet0 --allocation-id $eipalloc --query NatGateway.NatGatewayId --output text)

echo sleeping for 40 seconds
sleep 40

# Create route in Private subnet to use NAT gateway
aws ec2 create-route --route-table-id "$PrivRouteTable" --destination-cidr-block 0.0.0.0/0 --gateway-id "$natID" --query 'Return' --output text

# Create private EC2 Instance
privEC2ID=$(aws ec2 run-instances --image-id ami-0b0dcb5067f052a63 --count 1 --instance-type t2.micro --key-name CSE3ACX-A3-key-pair --security-group-ids "$privateHostSG" --subnet-id "$subnet1" --user-data file://CSE3ACX-A3-private-user-data.txt --query Instances[].InstanceId --output text)

# Determine the IP address for the private EC2 instance
privIP=$(aws ec2 describe-instances --instance-ids $privEC2ID --query Reservations[].Instances[].PrivateIpAddress --output text)

# Get status of EC2 instances 
pubHostStatus=$(aws ec2 describe-instance-status --instance-id $pubEC2ID --query InstanceStatuses[].SystemStatus.Details[].Status --output text)
privHostStatus=$(aws ec2 describe-instance-status --instance-id $privEC2ID --query InstanceStatuses[].SystemStatus.Details[].Status --output text)

# Keep checking until they are running so we can copy ssh key to public host
while [ "$pubHostStatus" != "passed" ]
do 
  echo -e "\t\t Public host status is $pubHostStatus waiting 10 seconds and trying again."
  pubHostStatus=$(aws ec2 describe-instance-status --instance-id $pubEC2ID --query InstanceStatuses[].SystemStatus.Details[].Status --output text)
  sleep 10
done

while [ "$privHostStatus" != "passed" ]
do 
  echo -e "\t\t Private host status is $privHostStatus waiting 10 seconds and trying again."
  privHostStatus=$(aws ec2 describe-instance-status --instance-id $privEC2ID --query InstanceStatuses[].SystemStatus.Details[].Status --output text)
  sleep 10
done

# Copy private key to public host
scp -o StrictHostKeyChecking=no  -i ~/.ssh/CSE3ACX-A3-key-pair.pem  ~/.ssh/CSE3ACX-A3-key-pair.pem ec2-user@$pubIP:~/.ssh/CSE3ACX-A3-key-pair.pem

#######  Elastic Load Balancer stuff

# Create public subnet (ELB requires 2 subnets in different AZs)
subnet2=$(aws ec2 create-subnet --vpc-id "$VPC" --cidr-block 172.16.2.0/24 --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=Subnet2 Public}]' --availability-zone us-east-1b --query Subnet.SubnetId --output text)

# Create Security Group for ELB
elbSG=$(aws ec2 create-security-group --group-name elbSG --description "Security group for Elastic Load Balancer" --vpc-id "$VPC" --query 'GroupId' --output text)

# Allow http from ELB
aws ec2 authorize-security-group-ingress --group-id "$privateHostSG" --protocol tcp --port 80 --source-group "$elbSG"  --query 'Return' --output text

# Allow HTTP 
aws ec2 authorize-security-group-ingress --group-id "$elbSG" --protocol tcp --port 80 --cidr 0.0.0.0/0 --query 'Return' --output text

# Create Elastic Load Balancer
elbv2ARN=$(aws elbv2 create-load-balancer --name "CSE3ACX A3 elb" --subnets "$subnet0" "$subnet2" --security-groups "$elbSG" --query LoadBalancers[].LoadBalancerArn --output text)

# Create target group for private web server EC2 instances
targetGroupARN=$(aws elbv2 create-target-group --name "CSE3ACX-A3-web-targets" --protocol HTTP --port 80 --vpc-id "$VPC" --ip-address-type ipv4 --query TargetGroups[].TargetGroupArn --output text)

# Add Private EC2 instances to target group
aws elbv2 register-targets --target-group-arn "$targetGroupARN" --targets Id=$privEC2ID 

# Create listener on load balancer
listenerARN=$(aws elbv2 create-listener --load-balancer-arn "$elbv2ARN" --protocol HTTP --port 80 --default-actions Type=forward,TargetGroupArn=$targetGroupARN --query Listeners[].ListenerArn --output text)

# Determine DNS name
webURL=$(aws elbv2 describe-load-balancers --load-balancer-arns "$elbv2ARN" --query LoadBalancers[].DNSName --output text)


##############   End script #################

# Create json file of resources to cleanup
resources=~/resources.json
JSON_STRING=$( jq -n \
                  --arg vpcID "$VPC" \
                  --arg sn0 "$subnet0" \
                  --arg sn1 "$subnet1" \
                  --arg sn2 "$subnet2" \
                  --arg rtb "$PubRouteTable" \
                  --arg privRTB "$PrivRouteTable" \
                  --arg igw "$internetGateway" \
                  --arg sg "$publicSG" \
                  --arg privSG "$privateHostSG" \
                  --arg pubEC2 "$pubEC2ID" \
                  --arg privEC2ID "$privEC2ID" \
                  --arg natID "$natID" \
                  --arg eipalloc "$eipalloc" \
                  --arg elbSG "$elbSG" \
                  --arg elbv2ARN "$elbv2ARN" \
                  --arg targetGroupARN "$targetGroupARN" \
                  --arg listenerARN "$listenerARN" \
                  '{"VPC-ID": $vpcID, Subnet0: $sn0, Subnet1: $sn1, Subnet1: $sn2, PubRouteTable: $rtb, internetGateway: $igw, publicSG: $sg, pubEC2ID: $pubEC2, PrivRouteTable: $privRTB, privateHostSG: $privSG, privEC2ID: $privEC2ID, natID: $natID, eipalloc: $eipalloc, elbSG: $elbSG, elbv2ARN: $elbv2ARN, targetGroupARN: $targetGroupARN, listenerARN: $listenerARN}' )

echo $JSON_STRING > $resources

#  End of script status
greenText='\033[0;32m'
NC='\033[0m' # No Color
echo "Connect to the public host using the CLI command below from CloudShell"
echo -e "${greenText}\t\t ssh -i ~/.ssh/CSE3ACX-A3-key-pair.pem ec2-user@$pubIP ${NC}\n"
echo "Connect to private host using the CLI command below (on the public host)"
echo -e "${greenText}\t\t ssh -i ~/.ssh/CSE3ACX-A3-key-pair.pem ec2-user@$privIP ${NC}\n"
echo "Connect to website using the URL below"
echo -e "${greenText}\t\t http://"$webURL" ${NC}\n"