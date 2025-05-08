#!/usr/bin/env python3
"""
Simple MCP client example that connects to an MCP server using stdio or HTTP transport.

Usage:
    python3 mcp_client.py --transport [stdio|http] --url [url]

Example:
    # Connect to a stdio-based server
    python3 mcp_client.py --transport stdio --command "./zig-out/bin/mcp_server"
    
    # Connect to an HTTP-based server
    python3 mcp_client.py --transport http --url "http://127.0.0.1:7777/jsonrpc"
"""

import argparse
import json
import random
import requests
import subprocess
import sys
import threading
import time
from typing import Dict, Any, Optional, List

class McpClient:
    """Simple MCP client implementation."""
    
    def __init__(self):
        self.request_id = 0
        self.process = None
        self.url = None
        self.initialized = False
        self.capabilities = None
    
    def _get_request_id(self) -> int:
        """Generate a unique request ID."""
        self.request_id += 1
        return self.request_id
    
    def connect_stdio(self, command: List[str]) -> None:
        """Connect to an MCP server using stdio transport."""
        print(f"Starting MCP server: {' '.join(command)}")
        self.process = subprocess.Popen(
            command,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            universal_newlines=True,
            bufsize=1  # Line buffered
        )
        
        # Start a thread to read server's stderr and print it
        def read_stderr():
            while self.process.poll() is None:
                line = self.process.stderr.readline()
                if line:
                    print(f"SERVER LOG: {line.strip()}")
        
        threading.Thread(target=read_stderr, daemon=True).start()
    
    def connect_http(self, url: str) -> None:
        """Connect to an MCP server using HTTP transport."""
        self.url = url
        print(f"Connecting to MCP server at {url}")
    
    def send_request_stdio(self, method: str, params: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
        """Send a request to the server using stdio transport."""
        if self.process is None:
            raise RuntimeError("Not connected to a server")
        
        request = {
            "jsonrpc": "2.0",
            "id": self._get_request_id(),
            "method": method,
        }
        
        if params is not None:
            request["params"] = params
        
        request_str = json.dumps(request)
        print(f"Sending request: {request_str}")
        
        # Write the request to the server's stdin
        self.process.stdin.write(request_str + "\n")
        self.process.stdin.flush()
        
        # Read the response from the server's stdout
        response_str = self.process.stdout.readline().strip()
        print(f"Received response: {response_str}")
        
        return json.loads(response_str)
    
    def send_request_http(self, method: str, params: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
        """Send a request to the server using HTTP transport."""
        if self.url is None:
            raise RuntimeError("Not connected to a server")
        
        request = {
            "jsonrpc": "2.0",
            "id": self._get_request_id(),
            "method": method,
        }
        
        if params is not None:
            request["params"] = params
        
        request_str = json.dumps(request)
        print(f"Sending request: {request_str}")
        
        # Send the request to the server
        response = requests.post(self.url, json=request)
        response_str = response.text
        print(f"Received response: {response_str}")
        
        return json.loads(response_str)
    
    def send_request(self, method: str, params: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
        """Send a request to the server using the configured transport."""
        if self.process is not None:
            return self.send_request_stdio(method, params)
        elif self.url is not None:
            return self.send_request_http(method, params)
        else:
            raise RuntimeError("Not connected to a server")
    
    def initialize(self) -> None:
        """Initialize the MCP connection."""
        response = self.send_request("initialize", {
            "protocolVersion": "0.4.0",
            "capabilities": {
                "tools": {
                    "enabled": True
                }
            }
        })
        
        if "error" in response:
            raise RuntimeError(f"Failed to initialize: {response['error']}")
        
        self.capabilities = response["result"]["capabilities"]
        print(f"Server capabilities: {json.dumps(self.capabilities, indent=2)}")
        
        # Send initialized notification
        self.send_request("initialized")
        self.initialized = True
    
    def list_tools(self) -> List[Dict[str, Any]]:
        """Get the list of available tools."""
        response = self.send_request("mcp/tools/list")
        
        if "error" in response:
            raise RuntimeError(f"Failed to list tools: {response['error']}")
        
        tools = response["result"]["tools"]
        return tools
    
    def invoke_tool(self, name: str, params: Optional[Dict[str, Any]] = None) -> Any:
        """Invoke a tool on the server."""
        request_params = {
            "name": name
        }
        
        if params is not None:
            request_params["params"] = params
        
        response = self.send_request("mcp/tools/invoke", request_params)
        
        if "error" in response:
            raise RuntimeError(f"Failed to invoke tool: {response['error']}")
        
        return response["result"]
    
    def shutdown(self) -> None:
        """Shutdown the connection."""
        self.send_request("shutdown")
        
        if self.process is not None:
            self.process.terminate()
            self.process.wait()

def main():
    """Run the MCP client."""
    parser = argparse.ArgumentParser(description="Simple MCP client")
    parser.add_argument("--transport", choices=["stdio", "http"], required=True,
                        help="Transport to use (stdio or http)")
    parser.add_argument("--command", type=str, help="Command to run the MCP server (for stdio transport)")
    parser.add_argument("--url", type=str, help="URL of the MCP server (for HTTP transport)")
    
    args = parser.parse_args()
    
    client = McpClient()
    
    try:
        if args.transport == "stdio":
            if not args.command:
                parser.error("--command is required for stdio transport")
            client.connect_stdio(args.command.split())
        else:  # HTTP
            if not args.url:
                parser.error("--url is required for HTTP transport")
            client.connect_http(args.url)
        
        # Initialize the connection
        print("Initializing connection...")
        client.initialize()
        
        # List available tools
        print("\nListing available tools:")
        tools = client.list_tools()
        for tool in tools:
            print(f" - {tool['name']}: {tool['description']}")
        
        # Invoke the echo tool
        print("\nInvoking 'echo' tool:")
        echo_result = client.invoke_tool("echo", {"message": "Hello, MCP!"})
        print(f"Echo result: {json.dumps(echo_result, indent=2)}")
        
        # Invoke the reverse tool
        print("\nInvoking 'reverse' tool:")
        reverse_result = client.invoke_tool("reverse", {"text": "Hello, MCP!"})
        print(f"Reverse result: {json.dumps(reverse_result, indent=2)}")
        
        # Shutdown
        print("\nShutting down...")
        client.shutdown()
        
    except Exception as e:
        print(f"Error: {e}")
        if client is not None:
            client.shutdown()
        sys.exit(1)

if __name__ == "__main__":
    main()