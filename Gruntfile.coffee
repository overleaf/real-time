module.exports = (grunt) ->
	grunt.initConfig
		forever:
			app:
				options:
					index: "app.js"
		coffee:
			app_src:
				expand: true,
				flatten: true,
				cwd: "app"
				src: ['coffee/*.coffee'],
				dest: 'app/js/',
				ext: '.js'

			app:
				src: "app.coffee"
				dest: "app.js"

			unit_tests:
				expand: true
				cwd:  "test/unit/coffee"
				src: ["**/*.coffee"]
				dest: "test/unit/js/"
				ext:  ".js"

			acceptance_tests:
				expand: true
				cwd:  "test/acceptance/coffee"
				src: ["**/*.coffee"]
				dest: "test/acceptance/js/"
				ext:  ".js"

		watch:
			coffee:
				files: [ 'app.coffee', 'app/coffee/*.coffee' ]
				tasks: [ 'run' ]
				options:
					atBegin: true

		clean:
			app: ["app/js/"]
			unit_tests: ["test/unit/js"]
			acceptance_tests: ["test/acceptance/js"]
			smoke_tests: ["test/smoke/js"]

		express:
			options:
				script: 'app.js'
				delay: 1000

		mochaTest:
			unit:
				options:
					reporter: grunt.option('reporter') or 'spec'
					grep: grunt.option("grep")
				src: ["test/unit/js/**/*.js"]
			acceptance:
				options:
					reporter: grunt.option('reporter') or 'spec'
					timeout: 40000
					grep: grunt.option("grep")
				src: ["test/acceptance/js/**/*.js"]

	grunt.loadNpmTasks 'grunt-contrib-coffee'
	grunt.loadNpmTasks 'grunt-contrib-clean'
	grunt.loadNpmTasks 'grunt-contrib-watch'
	grunt.loadNpmTasks 'grunt-mocha-test'
	grunt.loadNpmTasks 'grunt-shell'
	grunt.loadNpmTasks 'grunt-express-server'

	grunt.loadNpmTasks 'grunt-bunyan'
	grunt.loadNpmTasks 'grunt-forever'

	grunt.registerTask 'compile:app', ['clean:app', 'coffee:app', 'coffee:app_src']
	grunt.registerTask 'run',         ['compile:app', 'bunyan', 'express']

	grunt.registerTask 'compile:unit_tests', ['clean:unit_tests', 'coffee:unit_tests']
	grunt.registerTask 'test:unit',          ['compile:app', 'compile:unit_tests', 'mochaTest:unit']

	grunt.registerTask 'compile:acceptance_tests', ['clean:acceptance_tests', 'coffee:acceptance_tests']
	grunt.registerTask 'test:acceptance',          ['compile:acceptance_tests', 'mochaTest:acceptance']

	grunt.registerTask 'install', 'compile:app'

	grunt.registerTask 'default', ['run']
