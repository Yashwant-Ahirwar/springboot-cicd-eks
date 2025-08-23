# ====== Build stage ======
FROM maven:3.9.8-eclipse-temurin-17 AS build
WORKDIR /app
COPY pom.xml .
RUN mvn -q -e -DskipTests dependency:go-offline   # ✅ Pre-downloads dependencies
COPY src ./src
RUN mvn -q -DskipTests package                     # ✅ Builds the JAR


# ====== Runtime stage ======
FROM eclipse-temurin:17-jre
WORKDIR /app
ENV JAVA_OPTS=""
COPY --from=build /app/target/app-0.0.1-SNAPSHOT.jar /app/app.jar
EXPOSE 8080
ENTRYPOINT ["sh", "-c", "java $JAVA_OPTS -jar /app/app.jar"]

RUN useradd -u 1001 appuser
USER appuser
