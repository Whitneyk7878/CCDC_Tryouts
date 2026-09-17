# HTTP
iptables -A INPUT -p tcp --dport 80 -j DROP
iptables -A INPUT -p tcp --dport 443 -j DROP

# Splunk web interface
iptables -A INPUT -p tcp --dport 8000 -j DROP

# Dovecot
iptables -A INPUT -p tcp --dport 110 -j DROP
iptables -A INPUT -p tcp --dport 143 -j DROP

# Postfix
iptables -A INPUT -p tcp --dport 25 -j DROP