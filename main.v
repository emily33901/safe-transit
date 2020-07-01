module main

import os
import flag

import apps

fn main() {
	fp := flag.new_flag_parser(os.args)
	fp.application('safe-transit')
	fp.version('v0.0.0')
	fp.description('Tcp relay')
	fp.skip_executable()
	
	// config
	relay_ip := fp.string('ip', `i`, '', 'IP+port of the relay (if running endpoint app)')
	relay_port := fp.int('relay_port', `p`, 7778, 'Port of the relay channel (if running in relay mode)')
	app_port := fp.int('app_port', `a`, 7777, 'Port of the application')
	
	// We only want one free arg for the app name
	fp.limit_free_args_to_exactly(1)
	fp.arguments_description('<app name (relay | endpoint | echo | ping)>')
	
	other_args := fp.finalize() or {
		println(err)
		println(fp.usage())
		return
	}

	match other_args[0] {
		'echo' {
			apps.echo(apps.Args{
				relay_port: relay_port
				app_port: 7779
				relay_ip: relay_ip
			})?
		}

		'ping' {
			apps.ping(apps.Args{
				relay_port: relay_port
				app_port: app_port
				relay_ip: relay_ip
			})?
		}

		'relay' {
			mut app := apps.new_relay(apps.Args{
				relay_port: relay_port
				app_port: app_port
				relay_ip: relay_ip
			})
			app.run()?
		}

		'endpoint' {
			mut app := apps.new_endpoint(apps.Args{
				relay_port: relay_port
				app_port: app_port
				relay_ip: relay_ip
			})
			app.run()?
		}

		else {
			println(fp.usage())
			println('Unknown app "${other_args[0]}"')
			return
		}
	}

	println('Shutting down...')
}
