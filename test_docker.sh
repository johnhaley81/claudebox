#!/bin/bash
echo "Testing Docker-in-Docker functionality..."
echo ""
echo "1. Docker version:"
docker --version
echo ""
echo "2. Docker info (short):"
docker info --format '{{json .}}' | jq -r '.ServerVersion, .OSType, .Architecture' 2>/dev/null || docker info | head -5
echo ""
echo "3. Running hello-world container:"
docker run --rm hello-world 2>&1 | head -20
echo ""
echo "Docker test complete!"