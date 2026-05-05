FROM eclipse-temurin:17-jre
WORKDIR /app
COPY target/*.jar app.jar
EXPOSE 8080
ENTRYPOINT [&quot;java&quot;,&quot;-jar&quot;,&quot;app.jar&quot;]