// Import and register all your controllers from the importmap via controllers/**/*_controller
import { application } from "controllers/application"
import { eagerLoadControllersFrom } from "@hotwired/stimulus-loading"
eagerLoadControllersFrom("controllers", application)

// FILTER:
import { application } from "controllers/application"
import AutosubmitController from "./autosubmit_controller"

application.register("autosubmit", AutosubmitController)
