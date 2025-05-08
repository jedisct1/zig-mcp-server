#!/usr/bin/env node
/**
 * Basic MCP client for testing the Zig MCP server
 */

const { spawn } = require('child_process');
const readline = require('readline');

// Start the MCP server process
const server = spawn('./zig-out/bin/mcp_server', []);

// Set up process event handlers
server.on('error', (err) => {
  console.error('Failed to start MCP server:', err);
  process.exit(1);
});

server.stderr.on('data', (data) => {
  console.error(`SERVER LOG: ${data}`);
});

// Set up readline interface to read responses
const rl = readline.createInterface({
  input: server.stdout,
  crlfDelay: Infinity
});

// Process responses
rl.on('line', (line) => {
  if (line.trim() === '') return;
  
  try {
    const response = JSON.parse(line);
    console.log('Server response:', JSON.stringify(response, null, 2));
  } catch (e) {
    console.log('Raw server output:', line);
  }
});

// Send initialize request
function initialize() {
  const request = {
    jsonrpc: '2.0',
    id: 1,
    method: 'initialize',
    params: {
      protocolVersion: '0.4.0',
      capabilities: {
        tools: {
          enabled: true
        }
      }
    }
  };
  
  console.log('Sending initialize request...');
  server.stdin.write(JSON.stringify(request) + '\n');
}

// Send initialized notification
function initialized() {
  const notification = {
    jsonrpc: '2.0', 
    method: 'initialized'
  };
  
  console.log('Sending initialized notification...');
  server.stdin.write(JSON.stringify(notification) + '\n');
}

// List tools
function listTools() {
  const request = {
    jsonrpc: '2.0',
    id: 2,
    method: 'mcp/tools/list'
  };
  
  console.log('Sending tools list request...');
  server.stdin.write(JSON.stringify(request) + '\n');
}

// Invoke echo tool
function invokeEchoTool() {
  const request = {
    jsonrpc: '2.0',
    id: 3,
    method: 'mcp/tools/invoke',
    params: {
      name: 'echo',
      params: {
        message: 'Hello from Node.js client!'
      }
    }
  };
  
  console.log('Invoking echo tool...');
  server.stdin.write(JSON.stringify(request) + '\n');
}

// Invoke reverse tool
function invokeReverseTool() {
  const request = {
    jsonrpc: '2.0',
    id: 4,
    method: 'mcp/tools/invoke',
    params: {
      name: 'reverse',
      params: {
        text: 'Hello from Node.js client!'
      }
    }
  };
  
  console.log('Invoking reverse tool...');
  server.stdin.write(JSON.stringify(request) + '\n');
}

// Shutdown server
function shutdown() {
  const request = {
    jsonrpc: '2.0',
    id: 5,
    method: 'shutdown'
  };
  
  console.log('Sending shutdown request...');
  server.stdin.write(JSON.stringify(request) + '\n');
  
  // Exit after a short delay
  setTimeout(() => {
    server.kill();
    process.exit(0);
  }, 1000);
}

// Execute test sequence with delays
setTimeout(initialize, 1000);
setTimeout(initialized, 2000);
setTimeout(listTools, 3000);
setTimeout(invokeEchoTool, 4000);
setTimeout(invokeReverseTool, 5000);
setTimeout(shutdown, 6000);