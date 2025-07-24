#!/bin/bash

# Flask Portfolio App - EC2 Application Setup Script
# This script runs on the EC2 instance to set up the Flask application
# Can be run manually if needed for debugging or re-deployment

set -e

# Configuration
GITHUB_REPO="https://github.com/hvardhan1024/Cloud_computing_el.git"  # Update this
APP_DIR="/home/ec2-user/flask-portfolio"
LOG_FILE="/var/log/portfolio-setup.log"

# Function to log messages
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a $LOG_FILE
}

log "🚀 Starting Flask Portfolio App setup on EC2..."

# Check if running as root or ec2-user
if [ "$EUID" -eq 0 ]; then
    USER_HOME="/home/ec2-user"
    DOCKER_USER="ec2-user"
else
    USER_HOME="$HOME"
    DOCKER_USER="$(whoami)"
fi

log "📦 Step 1: Installing system packages..."
sudo yum update -y
sudo yum install -y docker git curl

log "🐳 Step 2: Setting up Docker..."
sudo systemctl start docker
sudo systemctl enable docker
sudo usermod -a -G docker $DOCKER_USER

# Install Docker Compose
if ! command -v docker-compose &> /dev/null; then
    log "📥 Installing Docker Compose..."
    sudo curl -L "https://github.com/docker/compose/releases/download/1.29.2/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
    sudo chmod +x /usr/local/bin/docker-compose
fi

# Wait for Docker to be ready
log "⏳ Waiting for Docker to be ready..."
sleep 15

log "📁 Step 3: Setting up application directory..."
cd $USER_HOME

# Remove existing directory if it exists
if [ -d "$APP_DIR" ]; then
    log "🗑️ Removing existing application directory..."
    sudo rm -rf $APP_DIR
fi

log "📥 Step 4: Cloning repository..."
if ! git clone $GITHUB_REPO flask-portfolio; then
    log "❌ Failed to clone repository. Please check the GITHUB_REPO URL."
    exit 1
fi

cd flask-portfolio

# Check if Dockerfile exists
if [ ! -f "Dockerfile" ]; then
    log "❌ Dockerfile not found in repository!"
    exit 1
fi

# Check if requirements.txt exists
if [ ! -f "requirements.txt" ]; then
    log "❌ requirements.txt not found in repository!"
    exit 1
fi

log "⚙️ Step 5: Creating environment configuration..."

# Get metadata for S3 bucket and RDS info from environment or user data
# These should be passed from the deploy script
if [ -z "$DATABASE_URL" ]; then
    log "⚠️ DATABASE_URL not provided, using placeholder"
    DATABASE_URL="postgresql://postgres:password@localhost:5432/postgres"
fi

if [ -z "$S3_BUCKET" ]; then
    log "⚠️ S3_BUCKET not provided, using placeholder"
    S3_BUCKET="portfolio-app-placeholder"
fi

if [ -z "$AWS_REGION" ]; then
    AWS_REGION="ap-south-1"
fi

# Get AWS credentials from EC2 instance role or environment
if [ -z "$AWS_ACCESS_KEY_ID" ]; then
    log "ℹ️ AWS_ACCESS_KEY_ID not provided - will use IAM role"
    AWS_ACCESS_KEY_ID=""
fi

if [ -z "$AWS_SECRET_ACCESS_KEY" ]; then
    log "ℹ️ AWS_SECRET_ACCESS_KEY not provided - will use IAM role"
    AWS_SECRET_ACCESS_KEY=""
fi

# Create .env file
cat > .env << EOF
# Database Configuration
DATABASE_URL=$DATABASE_URL

# Flask Configuration
SECRET_KEY=simple-secret-key-$(date +%s)
FLASK_ENV=production
FLASK_DEBUG=False

# AWS Configuration
AWS_REGION=$AWS_REGION
S3_BUCKET=$S3_BUCKET
AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID
AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY

# Application Settings
PORT=5000
UPLOAD_MAX_SIZE=16777216
EOF

log "✅ Environment file created"

log "🔨 Step 6: Building Docker image..."
if sudo docker build -t portfolio-app .; then
    log "✅ Docker image built successfully"
else
    log "❌ Failed to build Docker image"
    exit 1
fi

log "🚀 Step 7: Starting application container..."

# Stop and remove existing container if it exists
sudo docker stop portfolio-container 2>/dev/null || true
sudo docker rm portfolio-container 2>/dev/null || true

# Run the container
if sudo docker run -d \
    -p 5000:5000 \
    --env-file .env \
    --name portfolio-container \
    --restart unless-stopped \
    portfolio-app; then
    log "✅ Application container started successfully"
else
    log "❌ Failed to start application container"
    exit 1
fi

# Wait for application to start
log "⏳ Waiting for application to be ready..."
sleep 30

# Check if application is responding
if curl -f http://localhost:5000 >/dev/null 2>&1; then
    log "✅ Application is responding on port 5000"
else
    log "⚠️ Application may not be ready yet (this is normal, it might need more time)"
fi

log "🔧 Step 8: Setting up file permissions..."
sudo chown -R $DOCKER_USER:$DOCKER_USER $APP_DIR

log "📊 Step 9: Application status check..."
echo "Docker containers:"
sudo docker ps

echo ""
echo "Docker logs (last 20 lines):"
sudo docker logs --tail 20 portfolio-container

echo ""
echo "Environment variables:"
cat .env

log "🎉 Flask Portfolio App setup completed!"
log "📍 Application should be accessible at: http://$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4):5000"
log "📝 Logs are available at: $LOG_FILE"
log "🐳 Container name: portfolio-container"

echo ""
echo "🔍 Quick troubleshooting commands:"
echo "   View logs: sudo docker logs portfolio-container"
echo "   Restart app: sudo docker restart portfolio-container"
echo "   Check status: sudo docker ps"
echo "   Access container: sudo docker exec -it portfolio-container /bin/bash"