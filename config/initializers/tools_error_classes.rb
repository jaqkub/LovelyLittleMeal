# Configure Zeitwerk to ignore error_classes.rb and explicitly require it
# This file contains error classes that don't follow Zeitwerk's naming convention
# (error_classes.rb doesn't map to a constant name like Tools::ErrorClasses)
Rails.autoloaders.main.ignore(Rails.root.join("app/lib/tools/error_classes.rb"))

# Explicitly require the error classes so they're available
require_relative "../../app/lib/tools/error_classes"

