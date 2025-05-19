
import {
  to = aws_codebuild_project.project-using-github-app
  id = "Deploy-Terraform"
}

import {
  to = aws_db_instance.existing_rds
  id = "databaseaws"
}