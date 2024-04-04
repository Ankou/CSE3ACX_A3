#!/bin/bash

# Shell script to clean up resources
resources=~/resources.json

VPC=$( jq -r '."VPC-ID"' $resources )
subnet0=$( jq -r '."Subnet0"' $resources )
subnet1=$( jq -r '."Subnet1"' $resources )
PubRouteTable=$( jq -r '."PubRouteTable"' $resources )
PrivRouteTable=$( jq -r '."PrivRouteTable"' $resources )
internetGateway=$( jq -r '."internetGateway"' $resources )
natGateway=$( jq -r '."natID"' $resources )
#rtbassoc=$( aws ec2 describe-route-tables --filters 'Name=vpc-id,Values='$VPC | jq -r '."RouteTables"[]."Associations"[]."RouteTableAssociationId"' )
publicSG=$( jq -r '."publicSG"' $resources )
pubEC2ID=$( jq -r '."pubEC2ID"' $resources )
privEC2ID=$( jq -r '."privEC2ID"' $resources )
privateHostSG=$( jq -r '."privateHostSG"' $resources )
eipalloc=$( jq -r '."eipalloc"' $resources )

# Delete EC2 instance
aws ec2 terminate-instances --instance-ids $privEC2ID | grep nothing
aws ec2 terminate-instances --instance-ids $pubEC2ID | grep nothing

ec2status=$( aws ec2 describe-instances --instance-ids $pubEC2ID --query 'Reservations[].Instances[].State.Name' --output text  )

while [ $ec2status != "terminated" ]
do
  echo Status: $ec2status trying again in 10 seconds
  ec2status=$( aws ec2 describe-instances --instance-ids $pubEC2ID --query 'Reservations[].Instances[].State.Name' --output text  )
  sleep 10
done

echo Status: $ec2status Checking Private instance

# Also check the private EC2 instance is terminated 
ec2status=$( aws ec2 describe-instances --instance-ids $privEC2ID --query 'Reservations[].Instances[].State.Name' --output text  )

while [ $ec2status != "terminated" ]
do
  echo Status: $ec2status trying again in 10 seconds
  ec2status=$( aws ec2 describe-instances --instance-ids $privEC2ID --query 'Reservations[].Instances[].State.Name' --output text  )
  sleep 10
done

echo Status: Private instance is now $ec2status 

# Delete subnet
#aws ec2 delete-subnet --subnet-id $subnet0
#aws ec2 delete-subnet --subnet-id $subnet1

# Delete route
echo -e "\e[31mDeleting Public default route\e[0m"
aws ec2 delete-route --route-table-id $PubRouteTable --destination-cidr-block 0.0.0.0/0

echo -e "\e[31mDeleting Private default route route\e[0m"
aws ec2 delete-route --route-table-id $PrivRouteTable --destination-cidr-block 0.0.0.0/0

# Delete NAT gateway

echo -e "\e[31mDeleting NAT gateway\e[0m"
aws ec2 delete-nat-gateway --nat-gateway-id $natGateway

# Wait for NAT gateway to be deleted
natState=$(aws ec2 describe-nat-gateways --nat-gateway-ids $natGateway --query NatGateways[].State --output text)

while [ $natState != "deleted" ]
do
  echo NAT State: $natState trying again in 10 seconds
  natState=$(aws ec2 describe-nat-gateways --nat-gateway-ids $natGateway --query NatGateways[].State --output text)
  sleep 10
done

echo NAT State: $natState continuing

# Detach internet gateway
echo -e "\e[31mDetaching internet gateway\e[0m"
aws ec2 detach-internet-gateway --internet-gateway-id $internetGateway --vpc-id $VPC

# Delete internet gateway
echo -e "\e[31mDeleting internet gateway\e[0m"
aws ec2 delete-internet-gateway --internet-gateway-id $internetGateway

# Delete route table
echo -e "\e[31mDeleting Public route table\e[0m"
aws ec2 delete-route-table --route-table-id $PubRouteTable

echo -e "\e[31mDeleting Private route table\e[0m"
aws ec2 delete-route-table --route-table-id $PrivRouteTable


# Delete subnet
echo -e "\e[31mDeleting Public subnet\e[0m"
aws ec2 delete-subnet --subnet-id $subnet0

echo -e "\e[31mDeleting Private subnet\e[0m"
aws ec2 delete-subnet --subnet-id $subnet1

# Delete Segurity Group
echo -e "\e[31mDeleting Private Security Group\e[0m"
aws ec2 delete-security-group --group-id $privateHostSG

echo -e "\e[31mDeleting Public Security Group\e[0m"
aws ec2 delete-security-group --group-id $publicSG

# Release elastic IP
echo -e "\e[31mReleasing Elastic IP\e[0m"
aws ec2 release-address --allocation-id $eipalloc

# Delete VPC
cho -e "\e[31mDeleting VPC\e[0m"
aws ec2 delete-vpc --vpc-id $VPC

# Delete key-pair
aws ec2 delete-key-pair --key-name CSE3ACX-A3-key-pair | grep nothing 

rm -f $resources
rm -f ~/.ssh/CSE3ACX-A3-key-pair.pem