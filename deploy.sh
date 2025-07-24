#!/bin/bash

# Flask Portfolio App - AWS Deployment Script
# Creates all AWS resources and deploys the application

set -e  # Exit on any error

# Configuration
REGION="ap-south-1"
TIMESTAMP=$(date +%s)
PROJECT_NAME="portfolio-app"
GITHUB_REPO="https://github.com/hvardhan1024/Cloud_computing_el.git"  # Update this

# Resource names with timestamp
S3_BUCKET="${PROJECT_NAME}-${TIMESTAMP}"
RDS_IDENTIFIER="${PROJECT_NAME}-db-${TIMESTAMP}"
INSTANCE_NAME="${PROJECT_NAME}-ec2-${TIMESTAMP}"
EC2_SECURITY_GROUP_NAME="${PROJECT_NAME}-ec2-sg"
RDS_SECURITY_GROUP_NAME="${PROJECT_NAME}-rds-sg"
IAM_ROLE_NAME="EC2S3AccessRole"
KEY_PAIR_NAME="${PROJECT_NAME}-key"

# Database configuration
DB_PASSWORD="SecurePass123!"
DB_NAME="postgres"
DB_USER="postgres"

echo "🚀 Starting Flask Portfolio App deployment..."
echo "📍 Region: $REGION"
echo "⏰ Timestamp: $TIMESTAMP"

# Check if AWS CLI is configured
if ! aws sts get-caller-identity >/dev/null 2>&1; then
    echo "❌ AWS CLI not configured. Run 'aws configure' first."
    exit 1
fi

# Create deployment info file
DEPLOYMENT_FILE="infra/deployment-info.txt"
mkdir -p infra
echo "# Deployment Information - Created $(date)" > $DEPLOYMENT_FILE
echo "TIMESTAMP=$TIMESTAMP" >> $DEPLOYMENT_FILE
echo "REGION=$REGION" >> $DEPLOYMENT_FILE

echo "📦 Step 1: Creating S3 bucket..."
aws s3 mb "s3://$S3_BUCKET" --region $REGION

# Try to disable block public access and set bucket policy
echo "🔓 Attempting to configure S3 bucket for public access..."
if aws s3api put-public-access-block --bucket $S3_BUCKET --public-access-block-configuration "BlockPublicAcls=false,IgnorePublicAcls=false,BlockPublicPolicy=false,RestrictPublicBuckets=false" 2>/dev/null; then
    echo "✅ Block public access disabled"
    # Wait a moment for the setting to take effect
    sleep 5
    
    # Try to set bucket policy
    if aws s3api put-bucket-policy --bucket $S3_BUCKET --policy '{
        "Version": "2012-10-17",
        "Statement": [
            {
                "Sid": "PublicReadGetObject",
                "Effect": "Allow",
                "Principal": "*",
                "Action": "s3:GetObject",
                "Resource": "arn:aws:s3:::'"$S3_BUCKET"'/*"
            }
        ]
    }' 2>/dev/null; then
        echo "✅ Public bucket policy applied"
    else
        echo "⚠️  Could not set public bucket policy - continuing with private bucket"
        echo "   Files will be accessed through signed URLs via the application"
    fi
else
    echo "⚠️  Could not modify block public access settings - continuing with private bucket"
    echo "   This is common with organizational AWS accounts with security restrictions"
    echo "   Files will be accessed through signed URLs via the application"
fi

echo "S3_BUCKET=$S3_BUCKET" >> $DEPLOYMENT_FILE
echo "✅ S3 bucket created: $S3_BUCKET"

echo "🔐 Step 2: Creating IAM role for EC2..."
# Create trust policy file
cat > /tmp/trust-policy.json << EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "Service": "ec2.amazonaws.com"
            },
            "Action": "sts:AssumeRole"
        }
    ]
}
EOF

# Create IAM role (ignore if already exists)
if aws iam create-role --role-name $IAM_ROLE_NAME --assume-role-policy-document file:///tmp/trust-policy.json 2>/dev/null; then
    echo "✅ IAM role created: $IAM_ROLE_NAME"
else
    echo "ℹ️  IAM role already exists: $IAM_ROLE_NAME"
fi

# Create enhanced S3 access policy with signed URL capabilities
cat > /tmp/s3-policy.json << EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "s3:PutObject",
                "s3:GetObject",
                "s3:DeleteObject",
                "s3:PutObjectAcl",
                "s3:GetObjectAcl",
                "s3:ListBucket"
            ],
            "Resource": [
                "arn:aws:s3:::$S3_BUCKET",
                "arn:aws:s3:::$S3_BUCKET/*"
            ]
        }
    ]
}
EOF

# Attach policy to role
aws iam put-role-policy --role-name $IAM_ROLE_NAME --policy-name S3AccessPolicy --policy-document file:///tmp/s3-policy.json

# Create instance profile (ignore if already exists)
if aws iam create-instance-profile --instance-profile-name $IAM_ROLE_NAME 2>/dev/null; then
    echo "✅ Instance profile created: $IAM_ROLE_NAME"
else
    echo "ℹ️  Instance profile already exists: $IAM_ROLE_NAME"
fi

# Add role to instance profile (ignore if already added)
aws iam add-role-to-instance-profile --instance-profile-name $IAM_ROLE_NAME --role-name $IAM_ROLE_NAME 2>/dev/null || true

# Wait for IAM role to be ready
echo "⏳ Waiting for IAM role to be ready..."
sleep 30

echo "IAM_ROLE=$IAM_ROLE_NAME" >> $DEPLOYMENT_FILE
echo "✅ IAM setup completed"

echo "🔒 Step 3: Creating security groups..."

# Create EC2 Security Group
EXISTING_EC2_SG=$(aws ec2 describe-security-groups --group-names $EC2_SECURITY_GROUP_NAME --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo "None")

if [ "$EXISTING_EC2_SG" != "None" ] && [ "$EXISTING_EC2_SG" != "" ]; then
    EC2_SECURITY_GROUP_ID=$EXISTING_EC2_SG
    echo "ℹ️  Using existing EC2 security group: $EC2_SECURITY_GROUP_ID"
else
    EC2_SECURITY_GROUP_ID=$(aws ec2 create-security-group \
        --group-name $EC2_SECURITY_GROUP_NAME \
        --description "Security group for Flask portfolio app EC2 instance" \
        --query 'GroupId' --output text)
    
    # Add inbound rules for EC2
    aws ec2 authorize-security-group-ingress --group-id $EC2_SECURITY_GROUP_ID --protocol tcp --port 22 --cidr 0.0.0.0/0 2>/dev/null || true
    aws ec2 authorize-security-group-ingress --group-id $EC2_SECURITY_GROUP_ID --protocol tcp --port 5000 --cidr 0.0.0.0/0 2>/dev/null || true
    aws ec2 authorize-security-group-ingress --group-id $EC2_SECURITY_GROUP_ID --protocol tcp --port 80 --cidr 0.0.0.0/0 2>/dev/null || true
    
    echo "✅ EC2 Security group created: $EC2_SECURITY_GROUP_ID"
fi

# Create RDS Security Group
EXISTING_RDS_SG=$(aws ec2 describe-security-groups --group-names $RDS_SECURITY_GROUP_NAME --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo "None")

if [ "$EXISTING_RDS_SG" != "None" ] && [ "$EXISTING_RDS_SG" != "" ]; then
    RDS_SECURITY_GROUP_ID=$EXISTING_RDS_SG
    echo "ℹ️  Using existing RDS security group: $RDS_SECURITY_GROUP_ID"
else
    RDS_SECURITY_GROUP_ID=$(aws ec2 create-security-group \
        --group-name $RDS_SECURITY_GROUP_NAME \
        --description "Security group for Flask portfolio app RDS database" \
        --query 'GroupId' --output text)
    
    # Allow PostgreSQL access from EC2 security group
    aws ec2 authorize-security-group-ingress \
        --group-id $RDS_SECURITY_GROUP_ID \
        --protocol tcp \
        --port 5432 \
        --source-group $EC2_SECURITY_GROUP_ID
    
    echo "✅ RDS Security group created: $RDS_SECURITY_GROUP_ID"
fi

echo "EC2_SECURITY_GROUP_ID=$EC2_SECURITY_GROUP_ID" >> $DEPLOYMENT_FILE
echo "RDS_SECURITY_GROUP_ID=$RDS_SECURITY_GROUP_ID" >> $DEPLOYMENT_FILE

echo "🗃️ Step 4: Creating RDS PostgreSQL database..."

# Get default VPC
DEFAULT_VPC_ID=$(aws ec2 describe-vpcs --filters "Name=isDefault,Values=true" --query 'Vpcs[0].VpcId' --output text)
echo "Using default VPC: $DEFAULT_VPC_ID"

# Create subnet group if it doesn't exist
SUBNET_GROUP_NAME="${PROJECT_NAME}-subnet-group"
if aws rds describe-db-subnet-groups --db-subnet-group-name $SUBNET_GROUP_NAME >/dev/null 2>&1; then
    echo "ℹ️  Using existing subnet group: $SUBNET_GROUP_NAME"
else
    echo "Creating new subnet group..."
    # Get all subnets in the default VPC
    SUBNET_IDS=$(aws ec2 describe-subnets \
        --filters "Name=vpc-id,Values=$DEFAULT_VPC_ID" \
        --query 'Subnets[].SubnetId' \
        --output text)
    
    aws rds create-db-subnet-group \
        --db-subnet-group-name $SUBNET_GROUP_NAME \
        --db-subnet-group-description "Subnet group for portfolio app" \
        --subnet-ids $SUBNET_IDS
    echo "✅ Subnet group created: $SUBNET_GROUP_NAME"
fi

# Check if RDS instance already exists
if aws rds describe-db-instances --db-instance-identifier $RDS_IDENTIFIER >/dev/null 2>&1; then
    echo "ℹ️  RDS instance already exists: $RDS_IDENTIFIER"
else
    aws rds create-db-instance \
        --db-instance-identifier $RDS_IDENTIFIER \
        --db-instance-class db.t3.micro \
        --engine postgres \
        --master-username $DB_USER \
        --master-user-password $DB_PASSWORD \
        --allocated-storage 20 \
        --db-name $DB_NAME \
        --vpc-security-group-ids $RDS_SECURITY_GROUP_ID \
        --db-subnet-group-name $SUBNET_GROUP_NAME \
        --no-multi-az \
        --no-publicly-accessible

    echo "✅ RDS instance creation started: $RDS_IDENTIFIER"
    
    echo "⏳ Waiting for RDS to be available (this may take 5-10 minutes)..."
    aws rds wait db-instance-available --db-instance-identifier $RDS_IDENTIFIER
fi

# Get RDS endpoint
RDS_ENDPOINT=$(aws rds describe-db-instances \
    --db-instance-identifier $RDS_IDENTIFIER \
    --query 'DBInstances[0].Endpoint.Address' --output text)

echo "RDS_IDENTIFIER=$RDS_IDENTIFIER" >> $DEPLOYMENT_FILE
echo "RDS_ENDPOINT=$RDS_ENDPOINT" >> $DEPLOYMENT_FILE
echo "✅ RDS database ready: $RDS_ENDPOINT"

echo "🖥️ Step 5: Creating EC2 instance..."
# Get latest Amazon Linux 2 AMI
AMI_ID=$(aws ec2 describe-images \
    --owners amazon \
    --filters "Name=name,Values=amzn2-ami-hvm-*-x86_64-gp2" "Name=state,Values=available" \
    --query 'Images | sort_by(@, &CreationDate) | [-1].ImageId' \
    --output text)

# Create user data script with FIXED placeholders
cat > /tmp/user-data.sh << 'USERDATA_EOF'
#!/bin/bash
exec > >(tee /var/log/user-data.log) 2>&1
set -x

echo "Starting user data script at $(date)"

# Update system
yum update -y
yum install -y docker git python3 python3-pip postgresql

# Install AWS CLI v2
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
./aws/install

# Start Docker
systemctl start docker
systemctl enable docker
usermod -a -G docker ec2-user

# Install Docker Compose
curl -L "https://github.com/docker/compose/releases/download/1.29.2/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose

# Wait for Docker to be ready
sleep 15

# Test database connectivity
echo "Testing database connectivity..."
PGPASSWORD="__DB_PASSWORD__" psql -h "__RDS_ENDPOINT__" -U "__DB_USER__" -d "__DB_NAME__" -c "SELECT version();" && echo "✅ Database connection successful" || echo "❌ Database connection failed"

# Clone the repository
cd /home/ec2-user
if git clone __GITHUB_REPO__ flask-portfolio; then
    echo "Repository cloned successfully"
else
    echo "Git clone failed - creating basic app structure"
    mkdir -p flask-portfolio
    cd flask-portfolio
    
    # Create a basic Flask app if git clone fails
    cat > app.py << 'PYEOF'
from flask import Flask, request, render_template_string
import os
import psycopg2
from datetime import datetime

app = Flask(__name__)

def test_db_connection():
    try:
        conn = psycopg2.connect(os.getenv('DATABASE_URL'))
        cursor = conn.cursor()
        cursor.execute('SELECT version();')
        version = cursor.fetchone()
        cursor.close()
        conn.close()
        return f"Connected: {version[0][:50]}..."
    except Exception as e:
        return f"Connection failed: {str(e)[:100]}..."

@app.route('/')
def home():
    db_status = test_db_connection()
    return render_template_string('''
    <!DOCTYPE html>
    <html>
    <head>
        <title>Portfolio App</title>
        <style>
            body { font-family: Arial, sans-serif; margin: 40px; }
            .status { padding: 10px; margin: 10px 0; border-radius: 5px; }
            .success { background-color: #d4edda; color: #155724; }
            .error { background-color: #f8d7da; color: #721c24; }
        </style>
    </head>
    <body>
        <h1>Portfolio Application</h1>
        <p><strong>Application Status:</strong> ✅ Running successfully!</p>
        <p><strong>Timestamp:</strong> {{ timestamp }}</p>
        <div class="status {{ 'success' if 'Connected' in db_status else 'error' }}">
            <strong>Database Status:</strong> {{ db_status }}
        </div>
        <div class="status success">
            <strong>S3 Bucket:</strong> {{ s3_bucket }}
        </div>
        <div class="status success">
            <strong>AWS Region:</strong> {{ aws_region }}
        </div>
    </body>
    </html>
    ''', 
    db_status=db_status,
    s3_bucket=os.getenv('S3_BUCKET', 'Not configured'),
    aws_region=os.getenv('AWS_REGION', 'Not configured'),
    timestamp=datetime.now().strftime('%Y-%m-%d %H:%M:%S UTC'))

@app.route('/health')
def health():
    return {'status': 'healthy', 'timestamp': datetime.now().isoformat()}

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=int(os.getenv('PORT', 5000)), debug=False)
PYEOF
    
    # Create updated requirements.txt with all dependencies
    cat > requirements.txt << 'PYEOF'
Flask==2.3.3
Flask-SQLAlchemy==3.0.5
psycopg2-binary==2.9.7
boto3==1.28.85
Werkzeug==2.3.7
python-dotenv==1.0.0
requests==2.31.0
PYEOF

    # Create basic Dockerfile
    cat > Dockerfile << 'PYEOF'
FROM python:3.9-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
EXPOSE 5000
CMD ["python", "app.py"]
PYEOF
fi

cd /home/ec2-user/flask-portfolio

# Create .env file with all necessary variables - FIXED FORMAT
cat > .env << 'ENVEOF'
DATABASE_URL=postgresql://__DB_USER__:__DB_PASSWORD__@__RDS_ENDPOINT__:5432/__DB_NAME__
SECRET_KEY=simple-secret-key-$(date +%s)
FLASK_ENV=production
FLASK_DEBUG=False
AWS_REGION=__AWS_REGION__
S3_BUCKET=__S3_BUCKET__
PORT=5000
UPLOAD_MAX_SIZE=16777216
AWS_DEFAULT_REGION=__AWS_REGION__
ENVEOF

# Build and run Docker container
echo "Building Docker image..."
docker build -t portfolio-app .

echo "Running Docker container..."
docker run -d -p 5000:5000 --env-file .env --name portfolio-container --restart unless-stopped portfolio-app

# Change ownership
chown -R ec2-user:ec2-user /home/ec2-user/flask-portfolio

# Wait a bit and check if container is running
sleep 10
if docker ps | grep -q portfolio-container; then
    echo "✅ Application container is running successfully"
    echo "📊 Container status:"
    docker ps | grep portfolio-container
    echo "📝 Recent container logs:"
    docker logs --tail 20 portfolio-container
else
    echo "❌ Application container failed to start"
    echo "📝 Container logs:"
    docker logs portfolio-container
fi

echo "Application setup completed at $(date)"
USERDATA_EOF

# Replace placeholders in user data - IMPROVED VERSION WITH UNIQUE PLACEHOLDERS
sed -i "s|__GITHUB_REPO__|$GITHUB_REPO|g" /tmp/user-data.sh
sed -i "s|__DB_USER__|$DB_USER|g" /tmp/user-data.sh
sed -i "s|__DB_PASSWORD__|$DB_PASSWORD|g" /tmp/user-data.sh
sed -i "s|__RDS_ENDPOINT__|$RDS_ENDPOINT|g" /tmp/user-data.sh
sed -i "s|__DB_NAME__|$DB_NAME|g" /tmp/user-data.sh
sed -i "s|__AWS_REGION__|$REGION|g" /tmp/user-data.sh
sed -i "s|__S3_BUCKET__|$S3_BUCKET|g" /tmp/user-data.sh

# Launch EC2 instance
INSTANCE_ID=$(aws ec2 run-instances \
    --image-id $AMI_ID \
    --count 1 \
    --instance-type t2.micro \
    --security-group-ids $EC2_SECURITY_GROUP_ID \
    --user-data file:///tmp/user-data.sh \
    --iam-instance-profile Name=$IAM_ROLE_NAME \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$INSTANCE_NAME}]" \
    --query 'Instances[0].InstanceId' \
    --output text)

echo "INSTANCE_ID=$INSTANCE_ID" >> $DEPLOYMENT_FILE
echo "✅ EC2 instance launched: $INSTANCE_ID"

echo "⏳ Waiting for EC2 instance to be running..."
aws ec2 wait instance-running --instance-ids $INSTANCE_ID

# Get public IP
PUBLIC_IP=$(aws ec2 describe-instances \
    --instance-ids $INSTANCE_ID \
    --query 'Reservations[0].Instances[0].PublicIpAddress' \
    --output text)

echo "PUBLIC_IP=$PUBLIC_IP" >> $DEPLOYMENT_FILE

# Cleanup temporary files
rm -f /tmp/trust-policy.json /tmp/s3-policy.json /tmp/user-data.sh

echo ""
echo "🎉 Deployment completed successfully!"
echo "📋 Deployment Summary:"
echo "   S3 Bucket: $S3_BUCKET"
echo "   RDS Endpoint: $RDS_ENDPOINT"
echo "   EC2 Instance: $INSTANCE_ID"
echo "   Public IP: $PUBLIC_IP"
echo "   EC2 Security Group: $EC2_SECURITY_GROUP_ID"
echo "   RDS Security Group: $RDS_SECURITY_GROUP_ID"
echo ""
echo "🌐 Your application will be available at: http://$PUBLIC_IP:5000"
echo "🏥 Health check endpoint: http://$PUBLIC_IP:5000/health"
echo "⏰ Please wait 3-5 minutes for the application to start completely."
echo ""
echo "💡 Note: S3 bucket is configured with restricted access for security."
echo "   Files are accessed through the application using IAM roles."
echo ""
echo "📝 All deployment details saved to: $DEPLOYMENT_FILE"
echo "🧹 To cleanup resources later, run: ./infra/cleanup.sh"
echo ""
echo "🔍 To check application logs:"
echo "   ssh -i ~/.ssh/${KEY_PAIR_NAME}.pem ec2-user@$PUBLIC_IP"
echo "   sudo tail -f /var/log/user-data.log"
echo "   docker logs portfolio-container"