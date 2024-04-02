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

# Create private subnet in the new VPC
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
publicSG=$(aws ec2 create-security-group --group-name webApp-sg --description "Security group for host in public subnet" --vpc-id "$VPC" --query 'GroupId' --output text)

# Allow SSH and http traffic
aws ec2 authorize-security-group-ingress --group-id "$publicSG" --protocol tcp --port 22 --cidr 0.0.0.0/0 --query 'Return' --output text

# Create Security Group for private host
privateHostSG=$(aws ec2 create-security-group --group-name privateHost-sg --description "Security group for host in private subnet" --vpc-id "$VPC" --query 'GroupId' --output text)

# Allow SSH from private host
aws ec2 authorize-security-group-ingress --group-id "$privateHostSG" --protocol tcp --port 22 --source-group "$publicSG"  --query 'Return' --output text

# Create public EC2 Instance
pubEC2ID=$(aws ec2 run-instances --image-id ami-0b0dcb5067f052a63 --count 1 --instance-type t2.micro --key-name CSE3ACX-A3-key-pair --security-group-ids "$publicSG" --subnet-id "$subnet0" --user-data file://CSE3ACX-A3-public-user-data.txt --query Instances[].InstanceId --output text)

# Determine public IP address of instance
pubIP=$(aws ec2 describe-instances --instance-ids $pubEC2ID --query Reservations[].Instances[].PublicIpAddress --output text)



##############   End script #################

# Create json file of resources to cleanup
resources=~/resources.json
JSON_STRING=$( jq -n \
                  --arg vpcID "$VPC" \
                  --arg sn0 "$subnet0" \
                  --arg sn1 "$subnet1" \
                  --arg rtb "$PubRouteTable" \
                  --arg privRTB "$PrivRouteTable" \
                  --arg igw "$internetGateway" \
                  --arg sg "$publicSG" \
                  --arg privSG "$privateHostSG" \
                  --arg pubEC2 "$pubEC2ID" \
                  '{"VPC-ID": $vpcID, Subnet0: $sn0, Subnet1: $sn1, PubRouteTable: $rtb, internetGateway: $igw, publicSG: $sg, pubEC2ID: $pubEC2, PrivRouteTable: $privRTB, privateHostSG: $privSG}' )

echo $JSON_STRING > $resources

#  End of script status
greenText='\033[0;32m'
NC='\033[0m' # No Color
echo "Connect to CLI using the command below"
echo -e "\n${greenText}\t\t ssh -i ~/.ssh/CSE3ACX-A2-key-pair.pem ec2-user@$pubIP ${NC}\n"