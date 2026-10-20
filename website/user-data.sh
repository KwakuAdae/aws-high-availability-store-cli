#!/bin/bash
# Kwaku Online Store: runs once on every new EC2 instance the Auto Scaling group launches.
# Installs NGINX and writes the store page, including which server and Availability Zone served it,
# so you can watch the load balancer spread traffic and see replacement servers appear.
set -euo pipefail

dnf install -y nginx

# Instance details from the instance metadata service (IMDSv2: get a session token first)
TOKEN="$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 300")"
meta() { curl -s -H "X-aws-ec2-metadata-token: ${TOKEN}" "http://169.254.169.254/latest/meta-data/$1"; }
INSTANCE_ID="$(meta instance-id)"
AZ="$(meta placement/availability-zone)"
PRIVATE_IP="$(meta local-ipv4)"
LAUNCHED="$(date -u '+%Y-%m-%d %H:%M UTC')"

cat > /usr/share/nginx/html/index.html <<EOF
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Kwaku Online Store</title>
<style>
  body { font-family: Arial, sans-serif; margin: 0; background: #f4f6f9; color: #222; }
  header { background: #12345b; color: white; padding: 30px 20px; text-align: center; }
  header h1 { margin: 0 0 6px; }
  header p { margin: 0; opacity: 0.85; }
  main { max-width: 960px; margin: 0 auto; padding: 30px 20px; }
  h2 { color: #12345b; }
  .products { display: flex; flex-wrap: wrap; justify-content: center; gap: 20px; }
  .card { background: white; border-radius: 12px; padding: 20px; width: 260px;
          box-shadow: 0 4px 14px rgba(18, 52, 91, 0.10); text-align: center; }
  .icon { font-size: 44px; }
  .card ul { list-style: none; padding: 0; text-align: left; }
  .card li { display: flex; justify-content: space-between; padding: 6px 0; border-bottom: 1px solid #eef1f5; }
  .price { color: #0b7a3e; font-weight: bold; }
  .notice { margin-top: 26px; text-align: center; color: #6b7280; font-size: 14px; }
  .server { margin: 30px auto 0; max-width: 520px; background: #e8f0fb; border-left: 5px solid #12345b;
            padding: 14px 18px; border-radius: 8px; font-size: 14px; }
  .server code { background: white; padding: 2px 6px; border-radius: 4px; }
</style>
</head>
<body>
<header>
  <h1>Kwaku Online Store</h1>
  <p>Quality products. Reliable shopping.</p>
</header>
<main>
  <h2>Our Product Categories</h2>
  <div class="products">
    <div class="card">
      <div class="icon">👕</div>
      <h3>Clothing</h3>
      <ul>
        <li>Classic T-shirt <span class="price">£15</span></li>
        <li>Denim Jacket <span class="price">£55</span></li>
        <li>Running Trainers <span class="price">£70</span></li>
      </ul>
    </div>
    <div class="card">
      <div class="icon">💻</div>
      <h3>Electronics</h3>
      <ul>
        <li>Wireless Earbuds <span class="price">£49</span></li>
        <li>Smart Watch <span class="price">£129</span></li>
        <li>14" Laptop <span class="price">£649</span></li>
      </ul>
    </div>
    <div class="card">
      <div class="icon">👜</div>
      <h3>Accessories</h3>
      <ul>
        <li>Leather Wallet <span class="price">£25</span></li>
        <li>Backpack <span class="price">£40</span></li>
        <li>Sunglasses <span class="price">£30</span></li>
      </ul>
    </div>
  </div>
  <p class="notice">Demonstration store: products are for display only. No real orders or payments are processed.</p>
  <div class="server">
    Served by instance <code>${INSTANCE_ID}</code> in <code>${AZ}</code><br>
    Private IP <code>${PRIVATE_IP}</code> · launched ${LAUNCHED}
  </div>
</main>
</body>
</html>
EOF

# A tiny JSON endpoint for the test scripts (which server answered?)
cat > /usr/share/nginx/html/server.json <<EOF
{"instance_id": "${INSTANCE_ID}", "availability_zone": "${AZ}", "private_ip": "${PRIVATE_IP}", "launched": "${LAUNCHED}"}
EOF

systemctl enable --now nginx
